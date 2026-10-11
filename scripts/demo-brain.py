import copy
import json
import os
import random
import shutil
import sys
from datetime import datetime, timedelta, timezone

CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
HERO_A = "/tmp/m5-real"
HERO_B = "/tmp/m5-real2"


def ulid(rng):
    return "01M4" + "".join(rng.choice(CROCKFORD) for _ in range(22))


def stamp(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%S.000Z")


def only_run(source):
    qid = sorted(os.listdir(f"{source}/questions"))[0]
    rid = sorted(os.listdir(f"{source}/questions/{qid}/runs"))[0]
    return qid, rid, f"{source}/questions/{qid}"


def write_run(out, question, run, copy_evidence_from=None):
    qdir = f"{out}/questions/{question['id']}"
    rdir = f"{qdir}/runs/{run['id']}"
    os.makedirs(rdir, exist_ok=True)
    json.dump(question, open(f"{qdir}/question.json", "w"), indent=2)
    json.dump(run, open(f"{rdir}/run.json", "w"), indent=2)
    open(f"{rdir}/events.ndjson", "w").close()
    if copy_evidence_from and os.path.isdir(copy_evidence_from):
        shutil.copytree(copy_evidence_from, f"{rdir}/evidence", dirs_exist_ok=True)


def retime(run, start, minutes):
    run["created_at"] = stamp(start)
    finish = start + timedelta(minutes=minutes)
    run["updated_at"] = stamp(finish)
    run["finished_at"] = stamp(finish)
    run["pipeline"]["heartbeat_at"] = stamp(finish)
    run["stats"]["duration_s"] = minutes * 60.0
    return run


def build(out):
    rng = random.Random(7)
    now = datetime.now(timezone.utc)
    if os.path.isdir(out):
        shutil.rmtree(out)
    os.makedirs(out)
    heroes = []
    for source, tier, title, ago in [
        (HERO_A, "deep", "How big are the delivery apps' ad businesses?", timedelta(hours=1, minutes=10)),
        (HERO_B, "quick", "Netflix members and revenue, 2021–2024", timedelta(days=1, hours=2)),
    ]:
        qid, rid, qdir = only_run(source)
        question = json.load(open(f"{qdir}/question.json"))
        run = json.load(open(f"{qdir}/runs/{rid}/run.json"))
        question["title"] = title
        run["brief"].update({"title": title, "asked": question["original_text"], "tier": tier,
                             "suggested_tier": tier, "tier_reason": "",
                             "clarifications": [{"question": "What matters most?", "answer": "Ad revenue"},
                                                {"question": "Which companies?", "answer": "Instacart, Uber, DoorDash"}]
                             if tier == "deep" else []})
        retime(run, now - ago, 13 if tier == "deep" else 4)
        question["created_at"] = run["created_at"]
        write_run(out, question, run, f"{qdir}/runs/{rid}/evidence")
        heroes.append((question, run))
        answers = f"{source}/answers"
        if os.path.isdir(answers):
            shutil.copytree(answers, f"{out}/answers", dirs_exist_ok=True)

    (question_a, run_a), (question_b, run_b) = heroes

    follow = copy.deepcopy(run_a)
    follow["id"] = ulid(rng)
    follow["kind"] = "followup"
    follow["brief"].update({"question": "And what is DoorDash's ad margin?", "title": "DoorDash ad margin", "tier": "quick",
                            "clarifications": []})
    retime(follow, now - timedelta(minutes=35), 3)
    write_run(out, question_a, follow)

    clones = [
        ("running", "deep", "Order demand forecasting — model choice", timedelta(minutes=4), 0),
        ("complete", "quick", "How many items does a catering menu carry?", timedelta(hours=5), 3),
        ("failed", "deep", "Last-mile delivery cost per order", timedelta(days=1, hours=5), 6),
        ("cancelled", "deep", "Data visualisation for dietary reports", timedelta(days=2, hours=3), 9),
        ("complete", "deep", "Dietary norms for a catering menu", timedelta(days=2, hours=9), 17),
        ("complete", "quick", "How restaurant chains reduce food waste", timedelta(days=3, hours=1), 4),
        ("partial", "quick", "Pricing of lunch subscriptions", timedelta(days=4, hours=2), 5),
        ("halted", "quick", "Churn benchmarks for B2B SaaS", timedelta(hours=3), 0),
        ("complete", "deep", "Menu psychology in restaurants", timedelta(days=12), 14),
        ("complete", "deep", "How to assess an HR tool", timedelta(days=17), 19),
        ("complete", "quick", "Dynamic pricing for lunch", timedelta(days=21), 4),
    ]
    for status, tier, title, ago, minutes in clones:
        base_question, base_run = (question_b, run_b) if tier == "quick" else (question_a, run_a)
        question = copy.deepcopy(base_question)
        run = copy.deepcopy(base_run)
        question["id"] = ulid(rng)
        run["id"] = ulid(rng)
        run["question_id"] = question["id"]
        question["title"] = title
        question["original_text"] = title
        question["resolved_text"] = title
        question["run_ids"] = [run["id"]]
        run["brief"].update({"title": title, "question": title, "asked": title, "tier": tier, "suggested_tier": tier,
                             "clarifications": []})
        retime(run, now - ago, minutes)
        question["created_at"] = run["created_at"]
        run["status"] = status
        if status == "running":
            run["finished_at"] = None
            run["answer"] = None
            run["pipeline"]["heartbeat_at"] = stamp(now)
            run["pipeline"]["pid"] = 1
        if status in ("failed", "cancelled", "halted"):
            run["answer"] = None
        if status == "partial":
            run["limits"]["wall_hit"] = "hard"
            run["stats"]["partial"] = True
        if status == "halted":
            run["refusal"] = {"kind": "rate_limited", "reason": "Your Claude subscription's five hour usage limit is reached; it resets at 17:40 UTC. A run now would stop partway, so none was started."}
        write_run(out, question, run)

    unread = [q for q in os.listdir(f"{out}/questions")]
    read_at = {}
    for qid in unread:
        run_dir = f"{out}/questions/{qid}/runs"
        finishes = []
        for rid in os.listdir(run_dir):
            finished = json.load(open(f"{run_dir}/{rid}/run.json")).get("finished_at")
            if finished:
                finishes.append(finished)
        if finishes:
            read_at[qid] = max(finishes)[:19] + "Z"
    fresh = [q for q in unread if json.load(open(f"{out}/questions/{q}/question.json"))["title"] == "How many items does a catering menu carry?"]
    for qid in fresh:
        read_at.pop(qid, None)
    json.dump({"schema": "quorum.ui/1", "read_at": read_at}, open(f"{out}/ui-state.json", "w"), indent=2)
    print(out)
    print("hero question", question_a["id"], "run", run_a["id"])


if __name__ == "__main__":
    build(sys.argv[1] if len(sys.argv) > 1 else "/tmp/quorum-demo-brain")
