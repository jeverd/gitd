Output docs/demo.gif

Set Shell "bash"
Set FontSize 13
Set Width 1140
Set Height 780
Set Padding 20
Set Framerate 20
Set Theme "Catppuccin Mocha"

Type "DEMO_PACE=0.5 AGENT_TTL=3 tests/demo/agents.sh"
Sleep 400ms
Enter

Wait+Screen@60s /MVP OK/
Sleep 3s
