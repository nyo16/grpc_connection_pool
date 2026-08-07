# Dialyzer filters. Keep this list empty unless a warning is provably false.
#
# `list_unused_filters: true` in mix.exs makes an unused filter a hard error, so
# these entries expire loudly once upstream fixes the cause — they will not rot
# into silent suppression.
#
# The two filters that lived here through 0.5.1 covered one upstream typing
# regression in grpc 1.0.2: it extracted the tail of
# `GRPC.Client.Connection.connect/2` into a private `finalize_connection/2`
# whose success typing, analyzed alone, rejected the still-`nil` virtual channel
# `connect/2` passed it. Dialyzer concluded the call never returned, narrowed
# `GRPC.Stub.connect/2` to `{:error, _}`, and flagged the pool's `{:ok, channel}`
# branch and `monitor_connection/1` as dead code. grpc 1.0.3 fixed the typing,
# dialyzer reported both filters as unused, and they were removed.
[]
