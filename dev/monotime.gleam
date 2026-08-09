import gleam/int

@external(erlang, "erlang", "monotonic_time")
pub fn monotonic_time() -> Int {
  0
}

/// Milliseconds since an arbitrary but monotonic epoch. Used to time the
/// harness's worker phases.
pub fn now_ms() -> Int {
  case int.divide(monotonic_time(), 1_000_000) {
    Ok(ms) -> ms
    Error(_) -> 0
  }
}
