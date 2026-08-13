//// Levee-owned dependency surface for the Elixir `Levee.Protocol.Bridge`.
////
//// The bridge calls into the `spillway` protocol library (sequencing, message
//// types, JWT validation) and the `signet` token/JWT library (`Scope`,
//// `TokenClaims`) as Erlang modules on the BEAM code path. Previously those
//// modules were only present because `floodgate` happened to depend on them;
//// this package declares them as *direct* dependencies of Levee instead, so the
//// bridge's runtime deps are owned and pinned by Levee rather than inherited
//// transitively through floodgate's build.
////
//// The functions below intentionally touch both libraries so the dependency is
//// enforced at compile time: if either package's API drifts, this package fails
//// to build — an early signal, rather than a runtime failure in the bridge.

import signet/types
import spillway

/// The `doc:read` scope wire string, via signet's shared `Scope` vocabulary.
pub fn read_scope() -> String {
  types.scope_to_string(types.DocRead)
}

/// The spillway write-mode constant used by the sequencing bridge.
pub fn write_mode() {
  spillway.write_mode()
}
