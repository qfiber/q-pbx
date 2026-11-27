# Ecto.Multi and Gettext's generated plural code hold MapSets, which OTP 28's Dialyzer reports
# as opaque mismatches (a known false positive). Ignore only that warning class, only in these files.
[
  {"lib/qpbx/core/accounts.ex", :call_without_opaque},
  {"lib/qpbx/web/gettext.ex", :call_without_opaque}
]
