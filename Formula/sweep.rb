class Sweep < Formula
  desc "Safe, fast, and transparent macOS application uninstaller"
  homepage "https://github.com/hamimLohani/sweep"
  url "https://github.com/hamimlohani/sweep/archive/refs/tags/v1.0.1.tar.gz"
  sha256 "604d2a57c67075045da9bd388063d3b38c350e3087f04ac6187bd880c263d785"
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
  end
end
