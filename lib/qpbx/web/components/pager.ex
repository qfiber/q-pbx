defmodule QPBX.Web.Pager do
  @moduledoc """
  Pages of a list already in memory (tenants, plans): `paginate/3` cuts the page, `pager/1`
  draws "1–25 of 74" and the page links (patches, so the page number is in the URL).
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
  attr :to, :any, required: true, doc: "page number -> path"

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
        <.link
          patch={@to.(max(@page.page - 1, 1))}
          class={["join-item btn btn-sm", @page.page == 1 && "btn-disabled"]}
          aria-label={gettext("Previous page")}
        >
          <.icon name="hero-chevron-left" class="size-4 rtl:rotate-180" />
        </.link>
        <%= for n <- @numbers do %>
          <span :if={n == :gap} class="join-item btn btn-sm btn-disabled">…</span>
          <.link
            :if={n != :gap}
            patch={@to.(n)}
            class={["join-item btn btn-sm", n == @page.page && "btn-primary"]}
            aria-current={n == @page.page && "page"}
          >
            {n}
          </.link>
        <% end %>
        <.link
          patch={@to.(min(@page.page + 1, @page.pages))}
          class={["join-item btn btn-sm", @page.page == @page.pages && "btn-disabled"]}
          aria-label={gettext("Next page")}
        >
          <.icon name="hero-chevron-right" class="size-4 rtl:rotate-180" />
        </.link>
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
