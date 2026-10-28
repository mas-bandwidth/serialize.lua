; The serialize.lua roadmap: the data ROADMAP.md is generated from.
; Same shape as nova-sprint's docs/roadmap.sexp: data, never evaluated. Edit this file, then
; regenerate ROADMAP.md with the roadmap tool (github.com/mas-bandwidth/nova-tools/tools/roadmap):
;   roadmap --file docs/roadmap.sexp --out ROADMAP.md
; Never edit ROADMAP.md by hand. Created 2026-10-27 for the work left open when the port moved to
; standard 2.1. The U-rules audit and the three 2026-10-27 audit findings landed in 2.1.0
; (test/uniform); landed work is in git, so their items are gone from here.
(roadmap "v1"
 :title "serialize.lua roadmap"
 :text "Planned work for serialize.lua. At 2.1.0 (2026-10-27) the port keeps every uniform rule U1 to U16 of IMPLEMENTING.md and the three 2026-10-27 audit findings for it are fixed, each proved in test/uniform. Landed work is in git."

 :groups
 (
  (group "standard-2.1" :title "Standard 2.1: the uniform rules"
   :text "IMPLEMENTING.md U1 to U16 (vendored from serialize v2.1.0). All kept at 2.1.0; a rule the reference adds or tightens later lands here first.")
 )

 :items
 (
  (item "u9-reject-checked-only" :group "standard-2.1" :area "serialize.lua"
   :title "confirm reject on a write or measure raising is the right reading of U9 for a port with no release build"
   :text "IMPLEMENTING.md U2 makes reject on a write or a measure caller misuse, asserted in checked builds; U9 says it returns false and never panics in a release build. This port has one build, always checked (DESIGN.md (a), deviation 9), so stream:reject() on a write or a measure raises, as every other write-side misuse here does. Done when: the reference names how an always-checked port spells it, and this port matches that ruling with a unit test."
   :date "2026-10-27"
   :origin "2.1.0 U-rules audit, rowan/2.1.0-rules")
 ))
