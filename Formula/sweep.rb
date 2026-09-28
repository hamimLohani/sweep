class Sweep < Formula
  desc "Safe, fast, and transparent macOS application uninstaller"
  homepage "https://github.com/hamimLohani/sweep"
  url "https://github.com/hamimlohani/sweep/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "5a810712a19d92d411c01a8c53a42de5c28f43b8ab268727d4973291e53453bd"
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
