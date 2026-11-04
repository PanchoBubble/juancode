import Foundation
import Testing
import JuancodeCore
@testable import JuancodeDesktop

/// The Tickets panel scoped to the selected repository (juancode-18j.3): which tickets
/// a repository lists, that nothing is guessed for an unmapped one, that a late page
/// never lands under another project, and where "Work on" starts. No network.

private let eng = LinearTicketTarget.team(key: "ENG", name: "Engineering")
private let web = LinearTicketTarget.project(id: "p-web", name: "Web")

private func ticket(_ identifier: String, team: String = "ENG", project: String = "") -> LinearTicket {
    LinearTicket(id: "id-\(identifier)", identifier: identifier, title: identifier, url: "", priority: 0,
                 stateName: "Todo", stateType: "unstarted", stateColor: "", teamKey: team,
                 branchName: "", updatedAt: nil, projectId: project, projectName: "")
}

private func page(_ ids: [String], more: Bool = false, cursor: String? = nil) -> LinearTicketPage {
    LinearTicketPage(tickets: ids.map { ticket($0) }, hasNextPage: more, endCursor: cursor)
}

/// Linear, answered by hand: each request waits until the test resolves it.
@MainActor
private final class FakeLinear {
    struct Call {
        let query: LinearTicketQuery
        let first: Int
        let after: String?
        let reply: CheckedContinuation<Result<LinearTicketPage, LinearTicketsError>, Never>
    }
    var calls: [Call] = []
    var resolved = 0

    func call(_ q: LinearTicketQuery, _ first: Int, _ after: String?) async
        -> Result<LinearTicketPage, LinearTicketsError> {
        await withCheckedContinuation { calls.append(Call(query: q, first: first, after: after, reply: $0)) }
    }

    func answer(_ i: Int, _ r: Result<LinearTicketPage, LinearTicketsError>) async {
        calls[i].reply.resume(returning: r)
        resolved += 1
        await settle()
    }
}

/// Let spawned tasks and resumed continuations run.
@MainActor private func settle() async {
    for _ in 0..<50 { await Task.yield() }
}

@MainActor
private func makeModel(_ fake: FakeLinear, mappings: [String: LinearTicketTarget] = [:],
                       now: @escaping @Sendable () -> Date = { Date() }) throws -> (LinearTicketsModel, UserDefaults) {
    let suite = "LinearTicketScopingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    let model = LinearTicketsModel(defaults: defaults, fetch: { q, f, a in await fake.call(q, f, a) },
                                   fetchTargets: { .success([]) }, now: now)
    for (root, target) in mappings { model.setMapping(target, for: root) }
    return (model, defaults)
}

@Suite struct LinearTicketSourceTests {
    @Test func aMappedRepositoryListsOnlyItsTeamOrProject() {
        let maps = ["/r/api": eng, "/r/web": web]
        let api = resolveLinearTicketsSource(showAll: false, root: "/r/api/", mappings: maps)
        #expect(api == .project(root: "/r/api", target: eng))
        let q = LinearTicketQuery.of(api, scope: .open, search: "")
        #expect(q?.target == eng)
        let filter = linearTicketFilter(scope: .open, search: "", target: eng)
        #expect(filter["team"] as? [String: [String: String]] == ["key": ["eqIgnoreCase": "ENG"]])
        let projectFilter = linearTicketFilter(scope: .open, search: "", target: web)
        #expect(projectFilter["project"] as? [String: [String: String]] == ["id": ["eq": "p-web"]])
    }

    @Test func unmappedAndUnselectedFetchNothingAndAllIsExplicit() {
        let maps = ["/r/api": eng]
        // A folder named like a team is still not mapped to it.
        let eng = resolveLinearTicketsSource(showAll: false, root: "/r/ENG", mappings: maps)
        #expect(eng == .unmapped(root: "/r/ENG"))
        #expect(LinearTicketQuery.of(eng, scope: .open, search: "") == nil)
        #expect(LinearTicketQuery.of(.noProject, scope: .open, search: "") == nil)
        let all = resolveLinearTicketsSource(showAll: true, root: "/r/api", mappings: maps)
        #expect(all == .all)
        #expect(LinearTicketQuery.of(all, scope: .open, search: "")?.target == nil)
        #expect(linearTicketFilter(scope: .open, search: "", target: nil)["team"] == nil)
    }

    @Test func cacheKeysSeparateProjectStateAndSearch() {
        let keys = Set([
            LinearTicketQuery(target: eng, scope: .open, search: ""),
            LinearTicketQuery(target: web, scope: .open, search: ""),
            LinearTicketQuery(target: nil, scope: .open, search: ""),
            LinearTicketQuery(target: eng, scope: .done, search: ""),
            LinearTicketQuery(target: eng, scope: .open, search: "login"),
        ].map(\.cacheKey))
        #expect(keys.count == 5)
        // A rename keeps the same cached pages.
        #expect(LinearTicketQuery(target: .team(key: "ENG", name: "Eng 2"), scope: .open, search: "").cacheKey
                == LinearTicketQuery(target: eng, scope: .open, search: "").cacheKey)
    }

    @Test func trackedIssuesOnlySuggest() {
        let tracked = [
            TrackedIssue(identifier: "ENG-1", title: "", url: "", cwd: "/r/api", sessionId: "s1"),
            TrackedIssue(identifier: "ENG-2", title: "", url: "", cwd: "/r/api/", sessionId: "s2"),
            TrackedIssue(identifier: "OPS-3", title: "", url: "", cwd: "/r/api", sessionId: "s3"),
            TrackedIssue(identifier: "WEB-4", title: "", url: "", cwd: "/r/web", sessionId: "s4"),
        ]
        let s = suggestedLinearTargets(root: "/r/api", trackedIssues: tracked, known: [eng])
        #expect(s.map(\.identity) == ["team:ENG", "team:OPS"])
        #expect(s.first == eng)
    }
}

@Suite struct LinearStartWorkTests {
    @Test func projectViewStartsInThatRepository() {
        let maps = ["/r/api": eng]
        let r = linearStartWork(for: ticket("ENG-1"), source: .project(root: "/r/api", target: eng),
                                selectedRoot: "/r/api", mappings: maps)
        #expect(r == .root("/r/api"))
    }

    @Test func allProjectsRoutesToTheTicketsMappedRepository() {
        let maps = ["/r/api": eng, "/r/web": web, "/r/api2": eng]
        // The selected repository is one of the ticket's: it wins.
        #expect(linearStartWork(for: ticket("ENG-1"), source: .all, selectedRoot: "/r/api2", mappings: maps)
                == .root("/r/api2"))
        // Exactly one repository is mapped to the ticket's project.
        #expect(linearStartWork(for: ticket("X-1", team: "X", project: "p-web"), source: .all,
                                selectedRoot: "/r/api", mappings: maps) == .root("/r/web"))
        // Two are and the selected one isn't either: no guess.
        #expect(linearStartWork(for: ticket("ENG-2"), source: .all, selectedRoot: "/r/web", mappings: maps)
                == .ambiguous(["/r/api", "/r/api2"]))
        // Nothing mapped: the selected session's repository, or nothing at all.
        #expect(linearStartWork(for: ticket("Z-1", team: "Z"), source: .all, selectedRoot: "/r/web",
                                mappings: maps) == .root("/r/web"))
        #expect(linearStartWork(for: ticket("Z-1", team: "Z"), source: .all, selectedRoot: nil,
                                mappings: maps) == .needsSession)
    }
}

@MainActor @Suite struct LinearTicketsModelTests {
    @Test func unmappedRepositoryNeverFetchesOrShowsAnotherProjectsTickets() async throws {
        let fake = FakeLinear()
        let (m, _) = try makeModel(fake, mappings: ["/r/api": eng])
        m.setRoot("/r/api")
        await settle()
        #expect(fake.calls.count == 1)
        await fake.answer(0, .success(page(["ENG-1"])))
        #expect(m.tickets.map(\.identifier) == ["ENG-1"])

        m.setRoot("/r/unmapped")
        await settle()
        #expect(m.source == .unmapped(root: "/r/unmapped"))
        #expect(m.tickets.isEmpty)
        #expect(fake.calls.count == 1)

        m.setShowAll(true)
        await settle()
        #expect(fake.calls.count == 2)
        #expect(fake.calls[1].query.target == nil)
    }

    @Test func aLatePageFromTheFormerProjectNeverShows() async throws {
        let fake = FakeLinear()
        let (m, _) = try makeModel(fake, mappings: ["/r/api": eng, "/r/web": web])
        m.setRoot("/r/api")
        await settle()
        m.setRoot("/r/web")
        await settle()
        #expect(fake.calls.map { $0.query.target } == [eng, web])
        await fake.answer(1, .success(page(["WEB-1"])))
        await fake.answer(0, .success(page(["ENG-1"])))
        #expect(m.tickets.map(\.identifier) == ["WEB-1"])
        // It was still Linear's answer for api, so going back shows it without asking again.
        m.setRoot("/r/api")
        await settle()
        #expect(m.tickets.map(\.identifier) == ["ENG-1"])
        #expect(fake.calls.count == 2)
    }

    @Test func returningBeforeTheFetchLandsStillShowsIt() async throws {
        let fake = FakeLinear()
        let (m, _) = try makeModel(fake, mappings: ["/r/api": eng, "/r/web": web])
        m.setRoot("/r/api")
        await settle()
        m.setRoot("/r/web")
        await settle()
        m.setRoot("/r/api")
        await settle()
        #expect(fake.calls.count == 2) // api is still in flight; no duplicate request
        #expect(m.loading)
        await fake.answer(0, .success(page(["ENG-1"])))
        #expect(m.tickets.map(\.identifier) == ["ENG-1"])
        #expect(!m.loading)
    }

    @Test func aNextPageNeverLandsOnAnotherList() async throws {
        let fake = FakeLinear()
        let (m, _) = try makeModel(fake, mappings: ["/r/api": eng])
        m.setRoot("/r/api")
        await settle()
        await fake.answer(0, .success(page(["ENG-1"], more: true, cursor: "c1")))
        Task { await m.loadMore() }
        await settle()
        #expect(fake.calls[1].after == "c1")
        m.setScope(.done) // a filter switch while page two is in flight
        await settle()
        await fake.answer(1, .success(page(["ENG-2"])))
        #expect(!m.tickets.contains { $0.identifier == "ENG-2" })
        await fake.answer(2, .success(page(["ENG-9"])))
        #expect(m.tickets.map(\.identifier) == ["ENG-9"])
        #expect(fake.calls[2].query.scope == .done)
        #expect(fake.calls[2].after == nil)
    }

    @Test func searchAndFilterAreKeyedAndCachedPagesSpareLinear() async throws {
        let fake = FakeLinear()
        let (m, defaults) = try makeModel(fake, mappings: ["/r/api": eng])
        m.setRoot("/r/api")
        await settle()
        await fake.answer(0, .success(page(["ENG-1", "ENG-2"])))
        m.setSearch("login")
        await settle()
        #expect(fake.calls[1].query.search == "login")
        #expect(m.tickets.isEmpty)
        await fake.answer(1, .success(page(["ENG-2"])))
        m.setSearch("")
        await settle()
        #expect(m.tickets.map(\.identifier) == ["ENG-1", "ENG-2"])
        #expect(fake.calls.count == 2)

        // A relaunch inside the hour shows the cached page without asking.
        let again = LinearTicketsModel(defaults: defaults, fetch: { q, f, a in await fake.call(q, f, a) },
                                       fetchTargets: { .success([]) })
        again.setRoot("/r/api")
        await settle()
        #expect(again.tickets.map(\.identifier) == ["ENG-1", "ENG-2"])
        #expect(fake.calls.count == 2)
    }

    @Test func remappingSwitchesTheListImmediately() async throws {
        let fake = FakeLinear()
        let (m, _) = try makeModel(fake, mappings: ["/r/api": eng])
        m.setRoot("/r/api")
        await settle()
        await fake.answer(0, .success(page(["ENG-1"])))
        m.setMapping(web, for: "/r/api")
        #expect(m.tickets.isEmpty)
        await settle()
        #expect(fake.calls[1].query.target == web)
        m.setMapping(nil, for: "/r/api")
        #expect(m.source == .unmapped(root: "/r/api"))
        await fake.answer(1, .success(page(["WEB-1"])))
        #expect(m.tickets.isEmpty)
    }
}

@Suite struct ParseLinearTargetsTests {
    @Test func teamsThenProjects() throws {
        let raw = try JSONDecoder().decode(RawTargetsForTest.self, from: Data("""
        {"data":{"teams":{"nodes":[{"key":"ENG","name":"Engineering"},{"name":"no key"}]},
                 "projects":{"nodes":[{"id":"p1","name":"Web"},{"name":"no id"}]}}}
        """.utf8))
        #expect(try parseLinearTargets(raw).get() == [eng, .project(id: "p1", name: "Web")])
    }

    @Test func ticketsCarryTheirProject() throws {
        let raw = try JSONDecoder().decode(RawTicketsForTest.self, from: Data("""
        {"data":{"viewer":{"assignedIssues":{"nodes":[{"id":"u1","identifier":"ENG-1",
          "team":{"key":"ENG"},"project":{"id":"p-web","name":"Web"}}],"pageInfo":{"hasNextPage":false}}}}}
        """.utf8))
        let t = try parseLinearTickets(raw).get().tickets[0]
        #expect(t.projectId == "p-web")
        #expect(web.matches(t) && eng.matches(t))
    }
}
