
Solplanet Battery Energy Tracker — menubar-only macOS app for live inverter telemetry.

App (Swift package):  cd SolplanetEnergyTracker && swift build && swift test
Bootstrap plan:       ./docs/plans/plan_mac_bootstrap.md
Engineering rules:    ./CLAUDE.md  + ./docs/SWIFT-*.md
Full API reference:   ./docs/solplanet-api-documentation.md
Live status script:   ./scripts/battery_status.sh  (add --watch for live refresh)

How to query battery usage:

➜  /tmp curl -s -k "https://192.168.4.30/getdevdata.cgi?device=4&sn=AL010K5SQ2620429"
{"flg":1,"tim":"20260530072539","ppv":0,"etdpv":0,"etopv":0,"cst":10,"bst":2,"eb1":65535,"wb1":65535,"vb":5190,"cb":-69,"pb":-358,"tb":170,"soc":24,"soh":100,"cli":1000,"clo":1000,"ebi":0,"ebo":35,"eaci":0,"eaco":0,"vesp":2419,"cesp":1,"fesp":5000,"pesp":3,"rpesp":0,"etdesp":0,"etoesp":0,"iibs":1000,"iobs":1000,"vl1esp":0,"il1esp":0,"pac1esp":0,"qac1esp":0,"vl2esp":0,"il2esp":0,"pac2esp":0,"qac2esp":0,"vl3esp":0,"il3esp":0,"pac3esp":0,"qac3esp":0,"vbinv":5222,"cbinv":-79}%
➜  /tmp curl -s -k "https://192.168.4.30/getdevdata.cgi?device=3&sn=AL010K5SQ2620429"
{"flg":0,"tim":"","pac":0,"itd":0,"otd":0,"iet":0,"oet":0,"mod":12,"enb":1,"meter_general":{"prc":0,"sac":0,"iac":0,"avg_v":0,"avg_i":0,"fac":0,"pf":0},"vac_phs":[0,0,0],"iac_phs":[0,0,0],"vac_line":[0,0,0],"pac_phs":[0],"pf_phs":[0]}%
➜  /tmp curl -s -k "https://192.168.4.30/getdevdata.cgi?device=2&sn=AL010K5SQ2620429"
{"flg":1,"tim":"20260530072533","tmp":414,"fac":5000,"pac":-486,"sac":486,"qac":0,"eto":61,"etd":26,"hto":16,"pf":-99,"err":0,"vac":[2431],"iac":[21],"vpv":[0,0,0],"ipv":[0,0,0],"str":[],"stu":1,"pac1":-1,"qac1":-1,"pac2":-1,"qac2":-1,"pac3":-1,"qac3":-1,"grid_sts":1}%



