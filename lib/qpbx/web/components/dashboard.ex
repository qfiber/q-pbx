defmodule QPBX.Web.Dashboard do
  @moduledoc """
  Dashboard pieces: a stat card that opens its page, a panel for short lists, a status dot.
  Icon tiles take a tone so a grid of cards is not one colour (Meow's design rule).
  """
  use Phoenix.Component
  import QPBX.Web.CoreComponents, only: [icon: 1]

  attr :id, :string, required: true
  attr :navigate, :string, default: nil, doc: "the page behind the number; nil: not a link"
  attr :icon, :string, required: true
  attr :tone, :atom, default: :accent
  attr :label, :string, required: true
  attr :value, :any, required: true

  attr :alert, :boolean,
    default: false,
    doc: "draws attention (a red edge): something needs a look"

  slot :inner_block, doc: "a line under the number"

  def stat(assigns) do
    assigns = assign(assigns, :tile, QPBX.Web.UI.tone(assigns.tone))

    ~H"""
    <.link :if={@navigate} navigate={@navigate} id={@id} class={card_class(@alert, true)}>
      <.stat_body {assigns} />
    </.link>
    <div :if={!@navigate} id={@id} class={card_class(@alert, false)}>
      <.stat_body {assigns} />
    </div>
    """
  end

  defp card_class(alert, link?) do
    [
      "group block rounded-[12px] border bg-base-100 p-4 sm:p-5 shadow-card",
      link? &&
        "transition hover:-translate-y-0.5 hover:shadow-card-hover focus-visible:outline-2 focus-visible:outline-secondary",
      if(alert, do: "border-error/60", else: "border-hairline")
    ]
  end

  defp stat_body(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-3">
      <div class={["size-9 sm:size-10 rounded-[8px] grid place-items-center", @tile]}>
        <.icon name={@icon} class="size-5" />
      </div>
      <.icon
        :if={@navigate}
        name="hero-arrow-up-right"
        class="size-4 text-muted opacity-0 transition group-hover:opacity-100 rtl:-scale-x-100"
      />
    </div>
    <p class="mt-3 sm:mt-4 text-sm text-muted leading-snug">{@label}</p>
    <p class="mt-0.5 text-2xl sm:text-3xl font-semibold tracking-tight tabular-nums" dir="ltr">
      {@value}
    </p>
    <div :if={@inner_block != []} class="mt-1 text-xs text-muted">{render_slot(@inner_block)}</div>
    """
  end

  attr :used, :integer, required: true
  attr :of, :integer, required: true

  @doc "A thin bar: how much of an allowance is used (amber from 80%, red at 100%)."
  def meter(assigns) do
    pct = if assigns.of > 0, do: min(round(assigns.used * 100 / assigns.of), 100), else: 0
    assigns = assign(assigns, pct: pct)

    ~H"""
    <div class="mt-2 h-1.5 rounded-full bg-base-300 overflow-hidden">
      <div
        class={[
          "h-full rounded-full",
          cond do
            @pct >= 100 -> "bg-error"
            @pct >= 80 -> "bg-warning"
            true -> "bg-secondary"
          end
        ]}
        style={"width: #{@pct}%"}
      >
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :navigate, :string, required: true
  attr :more, :string, required: true
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section id={@id} class="rounded-[12px] border border-hairline bg-base-100 shadow-card">
      <header class="flex items-center justify-between gap-2 px-5 py-3 border-b border-hairline">
        <h2 class="font-semibold">{@title}</h2>
        <.link navigate={@navigate} class="text-sm text-secondary hover:underline">{@more}</.link>
      </header>
      <div class="divide-y divide-base-300">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr :status, :string, required: true

  def dot(assigns) do
    ~H"""
    <span class={[
      "inline-block size-2 rounded-full shrink-0",
      case @status do
        s when s in ["ok", "answered", "info"] -> "bg-success"
        s when s in ["warning", "not_configured", "busy"] -> "bg-warning"
        _ -> "bg-error"
      end
    ]}>
    </span>
    """
  end
end
