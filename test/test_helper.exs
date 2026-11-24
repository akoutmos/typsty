# Warnings are logged when documents render; tests that check them capture the log
Application.put_env(:typsty, :log_warnings, false)

ExUnit.start()
