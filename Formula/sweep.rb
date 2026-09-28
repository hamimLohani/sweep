class Sweep < Formula
  desc "Safe, fast, and transparent macOS application uninstaller"
  homepage "https://github.com/hamimLohani/sweep"
  url "https://github.com/hamimlohani/sweep/archive/refs/tags/v1.0.7.tar.gz"
  sha256 "ebdf3bddb3e084d4f6d5532f85cbfa4ac185d1eec37486cfc53910d28b9601f8"
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
