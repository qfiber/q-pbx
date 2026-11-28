defmodule QPBX.Web.Pager do
  @moduledoc """
  Pages of a list already in memory (tenants, plans): `paginate/3` cuts the page, `pager/1`
  draws "1–25 of 74" and the page buttons. Used through `QPBX.Web.PagedTable`.
  """
  use Phoenix.Component
  use Gettext, backend: QPBX.Web.Gettext
  import QPBX.Web.CoreComponents, only: [icon: 1]

  @per 25

  @doc "`%{items, page, pages, total, per}` for page `page` (a string from the URL, or a number)."
  def paginate(list, page, per \\ @per) do
    total = length(list)
    pages = max(div(total + per - 1, per), 1)
    page = page |> to_page() |> min(pages)

    %{
      items: Enum.slice(list, (page - 1) * per, per),
      page: page,
      pages: pages,
      total: total,
      per: per
    }
  end

  @doc "The page that holds the item with this id (after a save, show it)."
  def page_of(list, id, per \\ @per) do
    case Enum.find_index(list, &(&1.id == id)) do
      nil -> 1
      i -> div(i, per) + 1
    end
  end

  defp to_page(n) when is_integer(n) and n > 0, do: n

  defp to_page(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp to_page(_), do: 1

  attr :id, :string, required: true
  attr :page, :map, required: true, doc: "from paginate/3"
  attr :target, :any, required: true, doc: "the component that handles \"page\""

  @doc ~s[The count ("1–25 of 74") and the page buttons; they send "page" with the number to `target`.]
  def pager(assigns) do
    p = assigns.page
    first = if p.total == 0, do: 0, else: (p.page - 1) * p.per + 1

    assigns =
      assign(assigns, first: first, last: min(p.page * p.per, p.total), numbers: numbers(p))

    ~H"""
    <nav
      :if={@page.total > 0}
      id={@id}
      class="flex flex-wrap items-center justify-between gap-3 text-sm"
      aria-label={gettext("Pages")}
    >
      <span class="text-muted" dir="ltr">
        {gettext("%{first}–%{last} of %{total}", first: @first, last: @last, total: @page.total)}
      </span>
      <div :if={@page.pages > 1} class="join">
        <button
          type="button"
          phx-click="page"
          phx-value-page={@page.page - 1}
          phx-target={@target}
          disabled={@page.page == 1}
          class="join-item btn btn-sm"
          aria-label={gettext("Previous page")}
        >
          <.icon name="hero-chevron-left" class="size-4 rtl:rotate-180" />
        </button>
        <%= for n <- @numbers do %>
          <span :if={n == :gap} class="join-item btn btn-sm btn-disabled">…</span>
          <button
            :if={n != :gap}
            type="button"
            phx-click="page"
            phx-value-page={n}
            phx-target={@target}
            class={["join-item btn btn-sm", n == @page.page && "btn-primary"]}
            aria-current={n == @page.page && "page"}
          >
            {n}
          </button>
        <% end %>
        <button
          type="button"
          phx-click="page"
          phx-value-page={@page.page + 1}
          phx-target={@target}
          disabled={@page.page == @page.pages}
          class="join-item btn btn-sm"
          aria-label={gettext("Next page")}
        >
          <.icon name="hero-chevron-right" class="size-4 rtl:rotate-180" />
        </button>
      </div>
    </nav>
    """
  end

  # First, last, and two around the current page; gaps between.
  @doc false
  def numbers(%{page: page, pages: pages}) do
    [1, pages | Enum.to_list(max(page - 2, 1)..min(page + 2, pages))]
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.chunk_every(2, 1)
    |> Enum.flat_map(fn
      [a, b] when b - a > 1 -> [a, :gap]
      [a | _] -> [a]
    end)
  end
end
