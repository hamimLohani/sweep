class Sweep < Formula
  desc "Safe, fast, and transparent macOS application and package uninstaller"
  homepage "https://github.com/hamimLohani/sweep"
  url "https://github.com/hamimlohani/sweep/archive/refs/tags/v1.1.0.tar.gz"
  sha256 "53956178925b8f7328e29b18caa43213e1a2b5ab89c420a082d7dccec2830b33"
  license "MIT"
  head "https://github.com/hamimlohani/sweep.git", branch: "main"

  depends_on :macos

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/sweep"
    man1.install "man/sweep.1"
  end

  test do
    assert_match "sweep", shell_output("#{bin}/sweep --version")
    assert_match "Installed Applications", shell_output("#{bin}/sweep list")
    assert_match "pkg", shell_output("#{bin}/sweep --help")
  end
end
