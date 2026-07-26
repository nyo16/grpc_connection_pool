# Dialyzer filters. Keep this list empty unless a warning is provably false.
#
# `list_unused_filters: true` in mix.exs makes an unused filter a hard error, so
# these entries expire loudly once upstream fixes the cause — they will not rot
# into silent suppression.
#
# Both entries below stem from one upstream typing regression in grpc 1.0.2.
# 1.0.2 extracted the tail of `GRPC.Client.Connection.connect/2` into a private
# `finalize_connection/2` (1.0.1 had it inlined, and dialyzer was clean there).
# Analyzed on its own, that function's success typing demands a fully populated
# `%GRPC.Channel{}` — the one the load balancer hands back — while `connect/2`
# calls it with the *virtual* channel, whose `host`, `port`, and `adapter_payload`
# are still `nil`. Dialyzer therefore decides the call never returns:
#
#   connection.ex:190: The call finalize_connection(...) will never return since
#   it differs in the 1st argument from the success typing arguments
#
# so `GRPC.Stub.connect/2` narrows to `{:error, _}` (its own @spec says
# `{:ok, Channel.t()} | {:error, any()}`), and everything downstream of our
# success branch in `Worker.handle_info(:connect, _)` looks dead:
#
#   1. the `{:ok, channel}` clause "can never match"
#   2. `monitor_connection/1`, called only from that clause, is "never called"
#
# Both are false: the suite connects for real against a Cowboy h2c server and the
# Pub/Sub emulator (78 tests, `mix test --include emulator`), which exercises the
# ok branch and the gun-process monitor it installs. Remove these filters when
# grpc ships a fix — dialyzer will then fail with "Unused filters".
[
  ~r|worker\.ex:\d+:\d+:pattern_match The pattern can never match the type \{:error, _\}\.|,
  ~r|worker\.ex:\d+:\d+:unused_fun Function monitor_connection/1 will never be called\.|
]
