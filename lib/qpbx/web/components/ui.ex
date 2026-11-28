defmodule QPBX.Web.UI do
  @moduledoc """
  The portal's shared pieces beyond the core components (imported on every page): a letter
  avatar, a coloured chip, a titled section inside a form card and a smaller group inside it,
  the form's action bar, and the setup-link notice. Pages compose these instead of repeating
  markup; long lists use `QPBX.Web.PagedTable`.
  """
  use Phoenix.Component
  use Gettext, backend: QPBX.Web.Gettext
  import QPBX.Web.CoreComponents, only: [icon: 1]

  @tones %{
    brand: "bg-brand-pale text-primary",
    accent: "bg-accent-pale text-secondary",
    warm: "bg-warm-pale text-warm-ink",
    ok: "bg-ok-pale text-success",
    danger: "bg-error/10 text-error",
    plain: "bg-base-200 text-muted"
  }

  @doc "The classes of a tone (icon tiles, chips)."
  def tone(name), do: Map.fetch!(@tones, name)

  @doc "An alert severity's tone: critical red, warning amber, info cyan."
  def severity_tone("critical"), do: :danger
  def severity_tone("warning"), do: :warm
  def severity_tone(_), do: :accent

  @doc "An alert state's tone: open amber, acknowledged cyan, resolved green."
  def state_tone("open"), do: :warm
  def state_tone("acknowledged"), do: :accent
  def state_tone(_), do: :ok

  @doc "A call direction's icon."
  def direction_icon("inbound"), do: "hero-phone-arrow-down-left"
  def direction_icon("outbound"), do: "hero-phone-arrow-up-right"
  def direction_icon(_), do: "hero-phone"

  attr :name, :string, required: true
  attr :size, :atom, default: :md, values: [:sm, :md, :lg]
  attr :tone, :atom, default: :brand

  @doc "A rounded tile with the first letter of a name."
  def avatar(assigns) do
    ~H"""
    <span class={[
      "shrink-0 grid place-items-center font-semibold",
      tone(@tone),
      case @size do
        :sm -> "size-8 rounded-[8px] text-sm"
        :md -> "size-9 rounded-[8px]"
        :lg -> "size-12 rounded-[12px] text-xl"
      end
    ]}>
      {initial(@name)}
    </span>
    """
  end

  defp initial(name) when is_binary(name) and name != "",
    do: name |> String.first() |> String.upcase()

  defp initial(_), do: "?"

  attr :tone, :atom, default: :accent
  attr :rest, :global
  slot :inner_block, required: true

  @doc "A small coloured label: a plan, a role, a class, a feature, a state."
  def chip(assigns) do
    ~H"""
    <span class={["inline-block rounded-[6px] px-2 py-0.5 text-xs font-medium", tone(@tone)]} {@rest}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  attr :title, :string, required: true
  attr :icon, :string, required: true
  attr :hint, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  @doc "A titled block in a form card: icon tile and title on one line, the hint under the title."
  def section(assigns) do
    ~H"""
    <section class={["py-5 first:pt-0 last:pb-0", @class]}>
      <div class="mb-4">
        <div class="flex items-center gap-3">
          <div class={["size-8 shrink-0 rounded-[8px] grid place-items-center", tone(:accent)]}>
            <.icon name={@icon} class="size-4" />
          </div>
          <h2 class="font-semibold">{@title}</h2>
        </div>
        <p :if={@hint} class="mt-1 ps-11 text-sm text-muted">{@hint}</p>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :title, :string, required: true
  attr :icon, :string, required: true
  attr :hint, :string, default: nil
  slot :inner_block, required: true

  @doc "A group inside a section: a small icon and title, no tile."
  def field_group(assigns) do
    ~H"""
    <div class="pt-4 first:pt-0">
      <h3 class="flex items-center gap-2 mb-2 text-sm font-semibold text-secondary">
        <.icon name={@icon} class="size-4" />{@title}
      </h3>
      <p :if={@hint} class="-mt-1 mb-2 text-xs text-muted">{@hint}</p>
      {render_slot(@inner_block)}
    </div>
    """
  end

  slot :inner_block, required: true

  @doc "The bar under a form's sections: its buttons."
  def form_actions(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2 pt-5 mt-2 border-t border-base-300">
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :link, :map, default: nil, doc: "%{email, url}; nil: nothing shown"

  @doc "A new setup link, shown once to the admin who made it (it was emailed too)."
  def setup_link(assigns) do
    ~H"""
    <div
      :if={@link}
      class="rounded-[12px] border border-secondary/30 bg-accent-pale p-4 space-y-2"
      id="setup-link"
    >
      <p class="flex items-center gap-2 text-sm font-medium">
        <.icon name="hero-envelope" class="size-5 text-secondary" />
        {gettext("Setup link for %{email} (also emailed). It works once and expires in 48 hours:",
          email: @link.email
        )}
      </p>
      <code
        class="block break-all rounded-[8px] bg-base-100 border border-hairline p-2 text-xs"
        dir="ltr"
      >
        {@link.url}
      </code>
    </div>
    """
  end
end
