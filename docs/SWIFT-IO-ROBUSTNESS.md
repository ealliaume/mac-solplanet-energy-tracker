# Swift I/O robustness

## Atomic file writes

When writing data files (JSON, logs, config), always write to a temporary file first, then atomically rename. This prevents corruption if the process is killed mid-write.

```swift
// BAD — partial write on crash
try data.write(to: targetURL)

// GOOD — atomic rename
let tempURL = targetURL.appendingPathExtension("tmp")
try data.write(to: tempURL)
try FileManager.default.moveItem(at: tempURL, to: targetURL)

// ALSO GOOD — Foundation's built-in atomic option
try data.write(to: targetURL, options: .atomic)
```

## File locking: avoid TOCTOU and always set a timeout

When using `flock()` or any advisory lock:
- Never check-then-act (TOCTOU). Acquire the lock, then perform the operation, then release.
- Always set a timeout on lock acquisition. A hung process holding a lock must not block all future runs forever.
- Use `defer` to guarantee unlock.

```swift
// GOOD pattern
let fd = open(path, O_RDWR | O_CREAT, 0o644)
guard fd >= 0 else { throw IOError.cannotOpen(path) }
defer { close(fd) }

// Non-blocking attempt with retry + timeout
let deadline = Date().addingTimeInterval(5.0)
while flock(fd, LOCK_EX | LOCK_NB) != 0 {
    guard Date() < deadline else { throw IOError.lockTimeout(path) }
    try await Task.sleep(for: .milliseconds(50))
}
defer { flock(fd, LOCK_UN) }
```

## Efficient collection merges

When merging two collections by a key, use a dictionary for O(n+m) lookup instead of nested loops O(n*m).

```swift
// BAD — O(n*m)
for new in incoming {
    if let idx = existing.firstIndex(where: { $0.id == new.id }) {
        existing[idx] = new
    } else {
        existing.append(new)
    }
}

// GOOD — O(n+m)
var indexById = Dictionary(uniqueKeysWithValues: existing.enumerated().map { ($0.element.id, $0.offset) })
for item in incoming {
    if let idx = indexById[item.id] {
        existing[idx] = item
    } else {
        indexById[item.id] = existing.count
        existing.append(item)
    }
}
```

## Self-signed TLS: pin trust to configured hosts (never global ATS off)

The Solplanet/AISWEI dongle serves its local API over HTTPS with a **self-signed
certificate**. Do **not** disable App Transport Security globally
(`NSAllowsArbitraryLoads`) — that would trust every server the app ever talks to.

Instead, implement a `URLSessionDelegate` that overrides server-trust evaluation
**only when the challenge host matches a configured inverter host**. For any other
host, fall through to default handling (`.performDefaultHandling`).

```swift
// GOOD — host-pinned self-signed trust
func urlSession(_ session: URLSession,
                didReceive challenge: URLAuthenticationChallenge,
                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
          trustedHosts.contains(challenge.protectionSpace.host),
          let trust = challenge.protectionSpace.serverTrust else {
        completionHandler(.performDefaultHandling, nil)   // not our dongle → normal rules
        return
    }
    completionHandler(.useCredential, URLCredential(trust: trust))
}
```

- `trustedHosts` is derived from `ConnectionSettings`, injected — never hard-coded.
- Provide an `http` (port 8484) fallback for firmwares that expose plain HTTP, so
  TLS trust is opt-in per host rather than the app blanket-trusting the LAN.
- Covered by a test that asserts the evaluator trusts the configured host and
  rejects (default-handles) any other.
