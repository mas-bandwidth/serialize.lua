; The serialize.lua roadmap: the data ROADMAP.md is generated from.
; Same shape as nova-sprint's docs/roadmap.sexp: data, never evaluated. Edit this file, then
; regenerate ROADMAP.md with the roadmap tool (github.com/mas-bandwidth/nova-tools/tools/roadmap):
;   roadmap --file docs/roadmap.sexp --out ROADMAP.md
; Never edit ROADMAP.md by hand. Created 2026-10-27 for the work left open when the port moved to
; standard 2.1 (the wrap-up order: rejected and the re-vendor landed, the rest recorded here).
(roadmap "v1"
 :title "serialize.lua roadmap"
 :text "Planned work for serialize.lua. Created 2026-10-27, when the port moved to serialize standard 2.1 (v2.1.0): the rejected refusal reason (U2) and the v2.1.0 re-vendor landed; the remaining uniform rules of IMPLEMENTING.md and the 2026-10-27 audit findings are recorded here, each with its reproducer and the condition that closes it. Landed work is in git."

 :groups
 (
  (group "standard-2.1" :title "Standard 2.1: the uniform rules"
   :text "IMPLEMENTING.md U1 to U16 (vendored from serialize v2.1.0). U2 landed with 2.1.0; the rest are unaudited against this port.")
  (group "audit-2026-10-27" :title "Audit findings, 2026-10-27"
   :text "The cross-port security and correctness audit's findings for this port (AUDIT-LEDGER.md, heading lua). Reproducers are in /Volumes/nova/ai/rowan/working/serialize-love/audit2/serialize.lua/audit/. Each fix runs its reproducer first and confirms it fails.")
 )

 :items
 (
  (item "u-rules-audit" :group "standard-2.1" :area "serialize.lua"
   :title "audit U1 and U3 to U16 against this port, and fix each rule it breaks"
   :text "For each rule the port breaks: a unit test red now, the fix, the test green (no real time, no sockets, zero luacheck warnings). Rules already kept get a one-line note. Known starting points: U8/U9 (the over-wide serializeBits write below) and U16 (the precomputed compressed_float declaration below). Done when: every rule U1 to U16 is noted kept or has a landed test plus fix on green main."
   :date "2026-10-27"
   :origin "PORT-2.1-BRIEF.md step 4, deferred by the wrap-up order 2026-10-27")
  (item "ledger-precomputed-domain" :group "audit-2026-10-27" :area "serialize.lua"
   :title "M: the precomputed compressed_float check lacks a uint32 bound on maxIntegerValue (U16)"
   :text "serializeCompressedFloatPrecomputed accepts a maxIntegerValue outside uint32, giving wrong values or a raw raise. Same class as lobster's L finding. Reproducer: audit/precomputed_domain.lua. Done when: the reproducer passes: a maxIntegerValue outside uint32 raises (write, measure) and refuses as value_out_of_range (read) before any bit moves, with a unit test."
   :date "2026-10-27"
   :origin "AUDIT-LEDGER.md, lua, M")
  (item "ledger-bits-overwide" :group "audit-2026-10-27" :area "serialize.lua"
   :title "M: serializeBits writes an over-wide value masked, with no raise, despite the checked-writer doc (U8/U9)"
   :text "A write whose value does not fit its bit count is silently masked rather than raised as misuse, though DESIGN.md (g) says the writer is strict. Reproducer: audit/bits_overwide.lua. Resolve the U8/U9 tension against IMPLEMENTING.md first. Done when: the reproducer passes: an over-wide value raises on write and measure, naming the rule, with a unit test."
   :date "2026-10-27"
   :origin "AUDIT-LEDGER.md, lua, M")
  (item "ledger-lua32" :group "audit-2026-10-27" :area "serialize.lua"
   :title "L: no guard for LUA_32BITS; uint32 and uint8x8 reads go wrong or raise from the wire"
   :text "On an interpreter built with 32-bit integers the reader decodes wrong values or raises on hostile bytes. Reproducer: audit/int32_build.lua (with audit/lua32/). Done when: loading the library on a LUA_32BITS interpreter raises by name (math.maxinteger below 2^63 - 1), with a unit test that fakes the check."
   :date "2026-10-27"
   :origin "AUDIT-LEDGER.md, lua, L")
 ))
