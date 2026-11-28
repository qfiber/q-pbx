defmodule QPBX.Web.Logo do
  @moduledoc """
  The Q-PBX logo, drawn inline so it takes the theme's colour (`.qpbx-logo` in app.css: dark
  teal on light, light teal on dark). The shapes are read from `priv/static/images/logo.svg`
  when this module compiles, so that file stays the single source.
  """
  use Phoenix.Component

  @source Path.expand("../../../../priv/static/images/logo.svg", __DIR__)
  @external_resource @source
  @svg File.read!(@source)
  @mark for [_, t, d] <- Regex.scan(~r/<path transform="([^"]+)" d="([^"]+)"\/>/, @svg),
            do: %{t: t, d: d}
  @text Regex.run(~r/<path d="([^"]+)"\/>/, @svg) |> List.last()
  3 = length(@mark)

  attr :class, :string, default: "h-8"
  attr :mark_only, :boolean, default: false, doc: "the hexagon without the name"

  def logo(assigns) do
    assigns = assign(assigns, mark: @mark, text: @text)

    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox={if @mark_only, do: "0 0 193.6 223.51", else: "0 0 731.39484 223.50984"}
      class={["qpbx-logo", @class]}
      role="img"
      aria-label="Q-PBX"
    >
      <g fill="currentColor" transform="translate(219.075,-26.458333)">
        <g transform="matrix(7.7548499,0,0,7.7548499,-382.4277,-102.58696)">
          <path :for={p <- @mark} transform={p.t} d={p.d} />
        </g>
        <path :if={!@mark_only} d={@text} />
      </g>
    </svg>
    """
  end
end
