defmodule PpClientWeb.DnsRecordLiveTest do
  use PpClientWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PpClient.DnsRecord
  alias PpClient.DnsRecordManager

  @moduletag capture_log: true

  setup do
    # Clean out the test data
    Enum.each(DnsRecordManager.all_records(), &DnsRecordManager.delete_record(&1.domain))

    :ok
  end

  defp put_record(domain, ip, opts \\ []) do
    record =
      DnsRecord.new(%{domain: domain, ip: ip, enable: Keyword.get(opts, :enable, true)})

    {:ok, record} = DnsRecordManager.add_record(record)
    record
  end

  describe "Index" do
    test "lists the records", %{conn: conn} do
      put_record("listed.example.com", "203.0.113.5")

      {:ok, _view, html} = live(conn, ~p"/admin/dns")

      assert html =~ "DNS Records"
      assert html =~ "listed.example.com"
      assert html =~ "203.0.113.5"
    end

    test "shows an empty state when there is nothing to list", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/dns")

      assert html =~ "No DNS records yet"
    end

    test "searches by domain and by IP", %{conn: conn} do
      put_record("searched.example.com", "203.0.113.6")
      put_record("other.example.com", "198.51.100.6")

      {:ok, view, _html} = live(conn, ~p"/admin/dns")

      html = view |> element("form[phx-change='search']") |> render_change(%{search: "searched"})
      assert html =~ "searched.example.com"
      refute html =~ "other.example.com"

      html = view |> element("form[phx-change='search']") |> render_change(%{search: "198.51"})
      assert html =~ "other.example.com"
      refute html =~ "searched.example.com"

      html = view |> element("form[phx-change='search']") |> render_change(%{search: "nothing"})
      assert html =~ "No matching DNS record"
    end
  end

  describe "create" do
    test "saves a new record", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/dns")

      view |> element("button[phx-click='new']") |> render_click()

      html =
        view
        |> form("#dns-record-form",
          dns_record_schema: %{domain: "New.Example.COM", ip: "203.0.113.7"}
        )
        |> render_submit()

      assert html =~ "DNS record saved"
      assert html =~ "new.example.com"
      assert {:ok, {203, 0, 113, 7}} = DnsRecordManager.lookup("new.example.com")
    end

    test "reports an invalid IP on the field instead of saving", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/dns")

      view |> element("button[phx-click='new']") |> render_click()

      html =
        view
        |> form("#dns-record-form",
          dns_record_schema: %{domain: "bad-ip.example.com", ip: "999.1"}
        )
        |> render_submit()

      assert html =~ "invalid IP address format"
      refute DnsRecordManager.exists?("bad-ip.example.com")
    end

    test "reports a domain that is not a bare hostname", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/dns")

      view |> element("button[phx-click='new']") |> render_click()

      html =
        view
        |> form("#dns-record-form",
          dns_record_schema: %{domain: "https://example.com/ws", ip: "203.0.113.8"}
        )
        |> render_submit()

      assert html =~ "must be a bare hostname"
    end

    test "refuses a domain that already has a record", %{conn: conn} do
      put_record("taken.example.com", "203.0.113.9")

      {:ok, view, _html} = live(conn, ~p"/admin/dns")

      view |> element("button[phx-click='new']") |> render_click()

      html =
        view
        |> form("#dns-record-form",
          dns_record_schema: %{domain: "taken.example.com", ip: "203.0.113.10"}
        )
        |> render_submit()

      assert html =~ "already exists"
      assert {:ok, {203, 0, 113, 9}} = DnsRecordManager.lookup("taken.example.com")
    end
  end

  describe "edit" do
    test "changes the IP of an existing record", %{conn: conn} do
      put_record("edited.example.com", "203.0.113.11")

      {:ok, view, _html} = live(conn, ~p"/admin/dns")

      view
      |> element("#dns-records button[phx-value-domain='edited.example.com'][phx-click='edit']")
      |> render_click()

      html =
        view
        |> form("#dns-record-form",
          dns_record_schema: %{domain: "edited.example.com", ip: "203.0.113.12"}
        )
        |> render_submit()

      assert html =~ "203.0.113.12"
      assert {:ok, {203, 0, 113, 12}} = DnsRecordManager.lookup("edited.example.com")
    end

    test "renaming a record moves it to the new domain", %{conn: conn} do
      put_record("old.example.com", "203.0.113.13")

      {:ok, view, _html} = live(conn, ~p"/admin/dns")

      view
      |> element("#dns-records button[phx-value-domain='old.example.com'][phx-click='edit']")
      |> render_click()

      view
      |> form("#dns-record-form",
        dns_record_schema: %{domain: "new.example.com", ip: "203.0.113.13"}
      )
      |> render_submit()

      refute DnsRecordManager.exists?("old.example.com")
      assert {:ok, {203, 0, 113, 13}} = DnsRecordManager.lookup("new.example.com")
    end
  end

  describe "enable and delete" do
    test "toggles a record without removing it", %{conn: conn} do
      put_record("toggled.example.com", "203.0.113.14")

      {:ok, view, _html} = live(conn, ~p"/admin/dns")

      view
      |> element(
        "#dns-records button[phx-value-domain='toggled.example.com'][phx-click='toggle_enable']"
      )
      |> render_click()

      assert :miss = DnsRecordManager.lookup("toggled.example.com")
      assert DnsRecordManager.exists?("toggled.example.com")

      view
      |> element(
        "#dns-records button[phx-value-domain='toggled.example.com'][phx-click='toggle_enable']"
      )
      |> render_click()

      assert {:ok, {203, 0, 113, 14}} = DnsRecordManager.lookup("toggled.example.com")
    end

    test "deletes a record after the confirmation", %{conn: conn} do
      put_record("deleted.example.com", "203.0.113.15")

      {:ok, view, _html} = live(conn, ~p"/admin/dns")

      html =
        view
        |> element(
          "#dns-records button[phx-value-domain='deleted.example.com'][phx-click='delete_confirm']"
        )
        |> render_click()

      assert html =~ "Confirm deletion"
      assert DnsRecordManager.exists?("deleted.example.com")

      view |> element("#delete-dialog button[phx-click='delete']") |> render_click()

      refute DnsRecordManager.exists?("deleted.example.com")
    end
  end
end
