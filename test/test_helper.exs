# Warnings are logged when documents render; tests that check them capture the log
Application.put_env(:typsty, :log_warnings, false)

# Tests that need Unix tools, such as mkfifo
exclude = if match?({:win32, _}, :os.type()), do: [:unix], else: []

ExUnit.start(exclude: exclude)
