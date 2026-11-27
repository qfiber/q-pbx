# Ecto.Multi holds a MapSet, which OTP 28's Dialyzer reports as an opaque mismatch on every
# Multi pipeline (a known false positive). Ignore only that warning class, only in these files.
[
  {"lib/qpbx/core/accounts.ex", :call_without_opaque}
]
