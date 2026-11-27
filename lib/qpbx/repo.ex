defmodule QPBX.Repo do
  @moduledoc "The single Ecto repo. Each area queries only its own tables through it."
  use Boundary, deps: [], exports: []

  use Ecto.Repo,
    otp_app: :qpbx,
    adapter: Ecto.Adapters.Postgres
end
