class Sweep < Formula
  desc "Safe, fast, and transparent macOS application and package uninstaller"
  homepage "https://github.com/hamimLohani/sweep"
  url "https://github.com/hamimlohani/sweep/archive/refs/tags/v1.2.0.tar.gz"
  sha256 "1e36a762f345b0cafd311576d87a9627b0d27f6cbe3722a0cdc11de54b563de1"
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
    assert_match "brew", shell_output("#{bin}/sweep --help")
    assert_match "pkg", shell_output("#{bin}/sweep --help")
  end
end
