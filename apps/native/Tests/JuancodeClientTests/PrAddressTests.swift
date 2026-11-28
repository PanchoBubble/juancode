import Testing
@testable import JuancodeClient

@Suite struct PrAddressTests {
    @Test func acceptsWhatABrowserShowsForAPr() throws {
        let a = try #require(PrAddress(parsing: " https://github.com/acme/widgets/pull/42/files?diff=split#r1 \n"))
        #expect(a.host == "github.com")
        #expect(a.owner == "acme")
        #expect(a.repo == "widgets")
        #expect(a.number == 42)
        #expect(a.url == "https://github.com/acme/widgets/pull/42")
        let e = try #require(PrAddress(parsing: "http://ghe.example.com:8443/acme/widgets/pull/7"))
        #expect(e.url == "https://ghe.example.com:8443/acme/widgets/pull/7")
    }

    @Test func rejectsAnythingThatIsNotAPullRequestUrl() {
        for bad in ["", "not a url", "github.com/acme/widgets/pull/42",
                    "https://github.com/acme/widgets/issues/42",
                    "https://github.com/acme/widgets/pull/0",
                    "https://github.com/acme/widgets/pull/abc",
                    "https://github.com/acme/pull/42",
                    "https://github.com/../widgets/pull/42",
                    "https://user@github.com/acme/widgets/pull/42",
                    "ftp://github.com/acme/widgets/pull/42"] {
            #expect(PrAddress(parsing: bad) == nil, "accepted \(bad)")
        }
    }

    @Test func aCheckoutFreePrIsAddressedBySentinelCwdThatRoundTrips() throws {
        let a = try #require(PrAddress(parsing: "https://github.com/acme/widgets/pull/42"))
        #expect(PrAddress.isRemote(cwd: a.cwd))
        #expect(PrAddress(cwd: a.cwd) == a)
        #expect(!PrAddress.isRemote(cwd: "/Users/me/widgets"))
        #expect(PrAddress(cwd: "/Users/me/widgets") == nil)
        // Distinct repos never share a cache key even with the same PR number.
        let other = try #require(PrAddress(parsing: "https://github.com/acme/gadgets/pull/42"))
        #expect(a.cwd != other.cwd)
    }

    @Test func matchesTheRepoItsCheckoutsPointAt() throws {
        let a = try #require(PrAddress(parsing: "https://github.com/Acme/widgets/pull/42"))
        for ok in ["https://github.com/acme/widgets.git", "git@github.com:acme/widgets.git\n",
                   "ssh://git@github.com/acme/widgets", "https://github.com/acme/widgets/"] {
            #expect(a.isRepo(remote: ok), "rejected \(ok)")
        }
        for bad in ["https://github.com/acme/gadgets.git", "git@gitlab.com:acme/widgets.git",
                    "https://github.com/other/widgets", "widgets", ""] {
            #expect(!a.isRepo(remote: bad), "accepted \(bad)")
        }
    }
}
