; The serialize.lua roadmap: the data ROADMAP.md is generated from.
; Same shape as nova-sprint's docs/roadmap.sexp: data, never evaluated. Edit this file, then
; regenerate ROADMAP.md with the roadmap tool (github.com/mas-bandwidth/nova-tools/tools/roadmap):
;   roadmap --file docs/roadmap.sexp --out ROADMAP.md
; Never edit ROADMAP.md by hand. Created 2026-10-27 for the work left open when the port moved to
; standard 2.1. The U-rules audit and the three 2026-10-27 audit findings landed in 2.1.0
; (test/uniform); the 2.1.1 rulings (U6, U9, U15) landed in 2.1.1 (test/u9), closing
; u9-reject-checked-only. Landed work is in git, so their items are gone from here.
(roadmap "v1"
 :title "serialize.lua roadmap"
 :text "Planned work for serialize.lua. At 2.1.1 (2026-10-27) the port keeps every uniform rule U1 to U16 of IMPLEMENTING.md, as the reference's 2.1.1 rulings on U6, U9 and U15 read them: write and measure misuse traps (error()) in every run and never latches, and serialize.copyString is carried. Each is proved in test/uniform and test/u9. No work is open; a rule the reference adds or tightens later lands here first. Landed work is in git."

 :groups
 (
 )

 :items
 (
 ))
