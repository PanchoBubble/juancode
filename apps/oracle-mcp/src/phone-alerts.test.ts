import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { PhoneAlerts } from "./phone-alerts.ts";

const waiting = (id: string, notify = true) => ({
  sessionId: id,
  state: "waiting_input" as const,
  notify,
});

function setup() {
  const sent: string[] = [];
  const path = join(mkdtempSync(join(tmpdir(), "pa-")), "pa.json");
  const alerts = new PhoneAlerts(path, async (_t, id) => void sent.push(id));
  return { alerts, sent, path };
}

describe("phone alerts", () => {
  it("stays quiet while the Mac is attended and the session is not phone-driven", () => {
    const { alerts, sent } = setup();
    alerts.onEvent(waiting("a"));
    expect(sent).toEqual([]);
  });

  it("alerts once per entry when away, or when phone-driven; never when muted", () => {
    const { alerts, sent, path } = setup();
    alerts.setAway(true);
    alerts.onEvent(waiting("a"));
    alerts.onEvent(waiting("a")); // repeat frame, same wait
    alerts.setAway(false);
    alerts.markDriven("b");
    alerts.onEvent(waiting("b"));
    alerts.onEvent(waiting("c", false)); // connect-time snapshot
    alerts.setEnabled("b", false);
    alerts.onEvent({ sessionId: "b", state: "busy", notify: false });
    alerts.onEvent(waiting("b"));
    expect(sent).toEqual(["a", "b"]);
    // topic and mutes survive a restart
    const again = new PhoneAlerts(path);
    expect(again.state()).toMatchObject({ topic: alerts.topic, muted: ["b"] });
  });
});
