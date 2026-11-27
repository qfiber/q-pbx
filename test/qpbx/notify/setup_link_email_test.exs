defmodule QPBX.Notify.SetupLinkEmailTest do
  use QPBX.DataCase, async: true
  use Oban.Testing, repo: QPBX.Repo
  import Swoosh.TestAssertions
  alias QPBX.Notify.SetupLinkEmail

  test "the job sends the email" do
    args = %{
      "email" => "a@x.test",
      "name" => "A",
      "locale" => "en",
      "url" => "https://p.test/setup/t"
    }

    assert :ok = perform_job(SetupLinkEmail, args)
    assert_email_sent(subject: "Set up your Q-PBX account", to: [{"A", "a@x.test"}])
  end

  test "Arabic email is right-to-left and translated; names are escaped" do
    email = SetupLinkEmail.build("a@x.test", "<b>", "ar", "https://p.test/setup/t")
    assert email.subject == "إعداد حسابك على Q-PBX"
    assert email.html_body =~ ~s(dir="rtl")
    assert email.html_body =~ "&lt;b&gt;"
    assert email.text_body =~ "https://p.test/setup/t"
  end

  test "deliver_setup_link/2 queues one job on the notify queue" do
    {:ok, _} =
      QPBX.Notify.deliver_setup_link(
        %{email: "b@x.test", name: "B", locale: nil},
        "https://p.test/s"
      )

    assert_enqueued(
      worker: SetupLinkEmail,
      queue: :notify,
      args: %{"email" => "b@x.test", "locale" => "en"}
    )
  end
end
