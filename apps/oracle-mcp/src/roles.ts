// Loop roles (juancode-8oa5.7): the one place each role's prompt template lives. A
// dispatch that names a `role` carries only the task; the role's duties and the
// question format are appended here, and the RESULT contract after them as for every
// dispatch. The role also becomes the new session's label on its chain card.

export const ROLES = ["orchestrator", "planner", "implementer", "tester"] as const;
export type Role = (typeof ROLES)[number];

export function isRole(value: unknown): value is Role {
  return ROLES.includes(value as Role);
}

const DUTIES: Record<Role, string> = {
  orchestrator: `Your role: orchestrator. Drive the loop; do not implement or test yourself.
- Work comes from \`bd ready\` under your epic. Dispatch one implementer per ready ticket (role "implementer"), then one tester per finished implementation (role "tester"), passing ticket ids, not ticket text.
- Wait for each child's RESULT notification instead of polling. A tester pass closes the ticket; a failure goes back to an implementer with the tester's evidence.
- Cap failed rounds per ticket (default 3), then ask the human.`,
  planner: `Your role: planner. Turn the goal into beads tickets; do not implement.
- Create the tickets under the epic you were given (\`bd create --parent\`), each small enough for one session, with acceptance criteria and \`bd dep add\` for real ordering only.
- Your RESULT lists the ticket ids you created.`,
  implementer: `Your role: implementer. Implement exactly the ticket you were given.
- Read it with \`bd show <id>\`; follow the repo's AGENTS.md for gates, commit and push.
- Leave the ticket open for the tester unless your prompt says to close it. File follow-ups instead of widening scope.`,
  tester: `Your role: tester. Verify one implementation against its ticket; do not fix it.
- Read the ticket's acceptance criteria (\`bd show <id>\`) and check the change against each, running the relevant tests yourself.
- Pass: close the ticket and report status: done. Fail: leave it open and report status: blocked with the failing evidence an implementer can act on.`,
};

const QUESTION_FORMAT = `If you are blocked on a decision only the human can make, call the chain_ask tool (question, 2-4 options, the one you recommend, what stays blocked), then stop; the answer arrives as your next input.`;

/** The role's template, to follow the dispatch's task text. */
export function rolePrompt(role: Role): string {
  return `${DUTIES[role]}\n\n${QUESTION_FORMAT}`;
}
