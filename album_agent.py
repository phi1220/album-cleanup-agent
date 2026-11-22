from __future__ import annotations

import argparse
import itertools
import json
import os
import sys
from collections import Counter
from pathlib import Path

from agent_loop import JsonPlanner, LocalPlanner, run_agent, suggest_burst_skill
from qwen_api import DEFAULT_BASE_URL, DEFAULT_MODEL, QwenAdvisor, qwen_settings
import semantic_preferences
from album_core import (
    BASE, RANKS, JsonHttpAdvisor, apply_splits, contact_sheet, digest, model_advice,
    preferences, read_json, recommend, scan, write_json,
)

SPLITS = ("feedback", "validation", "test")


def records(state):
    return read_json(state / "reviews.json", [])


def bind_state(state, root):
    binding = state / "album.json"
    album = read_json(binding, {"root": str(root)})
    if Path(album["root"]) != root:
        raise ValueError("Use a separate --state directory for each album.")
    if not binding.exists():
        write_json(binding, album)


def manifest(state):
    result = read_json(state / "scan.json", None)
    if result is None:
        raise ValueError("Run scan first.")
    return result


def find_group(state, group_id):
    for group in manifest(state)["groups"]:
        if group["id"] == group_id:
            return group
    raise ValueError(f"Unknown photo group: {group_id}")


def version_store(state):
    return read_json(state / "versions.json", {
        "active": "v0",
        "versions": {"v0": {"harness": BASE, "status": "active", "parent": None}},
    })


def active_harness(state):
    versions = version_store(state)
    return versions["versions"][versions["active"]]["harness"]


def numbers(value, group, *, none_allowed=False):
    if value.casefold() == "all":
        return {p["id"] for p in group["photos"]}
    if value.casefold() == "none" and none_allowed:
        return set()
    indexes = [int(x) for x in value.split(",")]
    if not all(1 <= i <= len(group["photos"]) for i in indexes):
        raise ValueError("Enter valid photo numbers, separated by commas.")
    return {group["photos"][i - 1]["id"] for i in indexes}


def model_gateway():
    endpoint = os.environ.get("ALBUM_MODEL_URL")
    if endpoint:
        return JsonHttpAdvisor(endpoint, os.environ.get("ALBUM_MODEL_TOKEN"))
    config = qwen_settings(Path(__file__).resolve().with_name(".env"))
    api_key = config.get("QWEN_API_KEY") or config.get("DASHSCOPE_API_KEY")
    if not api_key:
        raise ValueError("Fill in QWEN_API_KEY in the project's .env file.")
    return QwenAdvisor(api_key, config.get("QWEN_BASE_URL") or DEFAULT_BASE_URL,
                       config.get("QWEN_MODEL") or DEFAULT_MODEL)


def check_model():
    result = model_gateway().advise({
        "operation": "album_agent.check_model",
        "instruction": 'Return exactly the JSON object {"ok": true}.',
    })
    if not isinstance(result, dict) or result.get("ok") is not True:
        raise ValueError("Model responded but did not return the expected JSON.")
    print("Model API connected and returned valid JSON.")


def show(state, group, *, remote=False, blind=False, proposal=None):
    review_log = records(state)
    rules = preferences(review_log)
    local = recommend(group, active_harness(state), rules)
    reason = ""
    model_result = None
    if proposal is not None:
        model_result, reason = proposal.keep_ids, proposal.reason
    elif remote:
        advisor = model_gateway()
        try:
            response = model_advice(advisor, group, state, local, rules,
                                    semantic_rules=semantic_preferences.active_rules(state))
            if response is not None:
                model_result, reason = response
        except (OSError, ValueError) as error:
            print(f"Model unavailable ({type(error).__name__}); showing local suggestions.", file=sys.stderr)
    shown = model_result if model_result is not None else local
    print(f"{group['id']} | {group['kind']} | {len(group['photos'])} photos")
    for path in contact_sheet(group, state):
        print(f"Preview: {path}")
    for i, p in enumerate(group["photos"], 1):
        note = "" if blind else ("keep" if p["id"] in shown else "cleanup candidate")
        print(f"  {i:>2}  {p['path']}  {note}")
        if p["text"] and not blind:
            print(f"      OCR: {' '.join(p['text'].split())[:120]}")
    if reason:
        print("Agent explanation:", " ".join(reason.split()))
    return shown


def record_review(args, state, proposal=None):
    group = find_group(state, args.group)
    previous = records(state)
    category = getattr(args, 'remember_category', None)
    condition = getattr(args, 'remember_when', None)
    if bool(category) != bool(condition):
        raise ValueError('Use --remember-category together with --remember-when.')
    known_hashes = {p["sha"] for p in group["photos"]}
    for record in previous:
        if record["split"] != args.split and known_hashes & {
            p["sha"] for p in record["group"]["photos"]
        }:
            raise ValueError("A photo or exact copy is already labeled in a different split.")
    if args.split != "feedback" and (args.scope != "once" or args.rank or args.allow_remote
                                     or args.use_for_evolution or category):
        raise ValueError("Validation and test labels are blind and do not update preferences.")
    if args.rank and args.scope == "once":
        raise ValueError("Select --scope kind or global to save a reusable ranking preference.")
    if proposal is not None:
        shown = proposal.keep_ids
    elif args.keep is None or args.allow_remote:
        shown = show(state, group, remote=args.allow_remote, blind=args.split != "feedback")
    else:
        shown = recommend(group, active_harness(state), preferences(previous))
    raw_keep = args.keep if args.keep is not None else input("Keep photo numbers (e.g. 1,3, all, none): ")
    keep = numbers(raw_keep.strip(), group, none_allowed=True)
    unsure = numbers(args.uncertain, group, none_allowed=True) if args.uncertain else set()
    if not keep and group["kind"] in {"copy", "burst", "similar"}:
        raise ValueError("Keep at least one photo in a duplicate or similar group.")
    if keep & unsure:
        raise ValueError("A photo can have only one label.")
    preference = proposal.semantic_rule if proposal is not None else None
    if category:
        preference = semantic_preferences.validate_rule({
            'category': category, 'condition': condition,
            'exceptions': getattr(args, 'remember_except', None) or '用户标记重要或有明确保留用途的照片除外。',
            'photo_ids': [p['id'] for p in group['photos'] if p['id'] not in unsure],
        }, {p['id'] for p in group['photos']})
        ids = set(preference['photo_ids'])
        if ids & keep and ids - keep:
            raise ValueError('Use consistently labeled examples when remembering a category preference.')
    policy = version_store(state)["active"]
    previous = [r for r in previous if r["group"]["id"] != group["id"]]
    entry = {
        "group": group, "split": args.split, "scope": args.scope, "rank": args.rank,
        "keep": sorted(keep), "uncertain": sorted(unsure), "reason": args.reason,
        "shown": sorted(shown) if args.split == "feedback" else None, "version": policy,
        "use_for_evolution": args.use_for_evolution,
        "agent_trace": proposal.trace if proposal is not None else [],
        "proposal_reason": proposal.reason if proposal is not None else "",
        "semantic_rule_proposal": preference,
        "semantic_version": semantic_preferences.store(state)['active'],
    }
    previous.append(entry)
    write_json(state / "reviews.json", previous)
    print(f"Saved {args.split} review for {group['id']}.")
    if args.split == 'feedback':
        if category:
            version = semantic_preferences.remember(state, preference, entry)
            print(f'Remembered content preference: {version}')
        else:
            semantic_preferences.confirm(state, preference, entry)


def agent_session(args, state):
    if args.rank and args.scope == "once":
        raise ValueError("Select --scope kind or global to save a reusable ranking preference.")
    if args.allow_remote and not args.group:
        raise ValueError("Specify --group to allow remote processing of that group only.")
    items = records(state)
    split_by_group = {r["group"]["id"]: r["split"] for r in items}
    if args.group:
        group = find_group(state, args.group)
        if split_by_group.get(group["id"], "feedback") != "feedback":
            raise ValueError("This group is reserved for evaluation.")
        groups = [group]
    else:
        order = {"copy": 0, "similar": 1, "burst": 2, "screenshot": 3}
        groups = sorted((g for g in manifest(state)["groups"] if g["kind"] in order
                         and g["id"] not in split_by_group), key=lambda g: order[g["kind"]])
    if args.allow_remote and len(groups[0]["photos"]) > 12:
        raise ValueError("Remote Agent review is limited to 12 photos per group.")
    planner = JsonPlanner(model_gateway()) if args.allow_remote else LocalPlanner()
    proposal = run_agent(args.task, groups, state, active_harness(state), preferences(items), planner,
                         ask_user=lambda q: input(q + " "), include_images=args.allow_remote,
                         semantic_rules=semantic_preferences.active_rules(state))
    print("Agent trace:", " -> ".join(step["tool"] for step in proposal.trace))
    show(state, proposal.group, proposal=proposal)
    keep = input("Keep photo numbers, all or none. Enter to skip: ").strip()
    if not keep:
        return
    uncertain = input("Uncertain photo numbers. Enter to skip: ").strip()
    record_review(argparse.Namespace(
        group=proposal.group["id"], keep=keep, uncertain=uncertain, split="feedback",
        scope=args.scope, rank=args.rank, reason=args.reason, allow_remote=False,
        use_for_evolution=args.use_for_evolution,
    ), state, proposal)


def split_group(args, state):
    album = manifest(state)
    group = find_group(state, args.group)
    if any(r["group"]["id"] == group["id"] for r in records(state)):
        raise ValueError("Split the group before recording its review.")
    parts = [numbers(part.strip(), group) for part in args.parts.split(";")]
    total = len(group["photos"])
    if len(parts) < 2 or sum(map(len, parts)) != total or len(set.union(*parts)) != total:
        raise ValueError("Enter two or more parts covering each photo exactly once, e.g. 1,2;3.")
    path = state / "splits.json"
    overrides = read_json(path, {})
    overrides[group["id"]] = [sorted(part) for part in parts]
    write_json(path, overrides)
    album["groups"] = apply_splits(album["groups"], overrides)
    write_json(state / "scan.json", album)
    print("Saved group split. Run groups --all for the new group IDs.")


def metrics(items, harness, rules):
    counts = Counter()
    for item in items:
        group = item["group"]
        predicted = recommend(group, harness, rules)
        keep, unsure = set(item["keep"]), set(item["uncertain"])
        ids = {p["id"] for p in group["photos"]}
        removable = ids - keep - unsure
        suggested = ids - predicted - unsure
        counts.update({
            "groups": 1, "keep": len(keep), "removable": len(removable),
            "suggested": len(suggested), "unsafe": len(suggested & keep),
            "correct_removals": len(suggested & removable),
            "edits": len((predicted ^ keep) - unsure),
        })
    def divide(n, d):
        return counts[n] / counts[d] if counts[d] else None

    return dict(counts) | {
        "false_cleanup_rate": divide("unsafe", "suggested"),
        "must_keep_violation_rate": divide("unsafe", "keep"),
        "cleanup_recall": divide("correct_removals", "removable"),
        "edits_per_group": divide("edits", "groups"),
    }


def qualifies(baseline, candidate):
    # Require observed examples for both cleanup and retention measurements.
    if baseline["groups"] < 2 or not baseline["keep"] or not baseline["removable"]:
        return False
    if baseline["false_cleanup_rate"] is None or candidate["false_cleanup_rate"] is None:
        return False
    return (
        candidate["false_cleanup_rate"] <= baseline["false_cleanup_rate"]
        and candidate["must_keep_violation_rate"] <= baseline["must_keep_violation_rate"]
        and candidate["cleanup_recall"] >= baseline["cleanup_recall"]
        and candidate["edits"] < baseline["edits"]
    )


def propose(state, *, remote=False):
    items = records(state)
    feedback = [r for r in items if r["split"] == "feedback" and r.get("use_for_evolution")
                and r["group"]["kind"] == "burst"]
    validation = [r for r in items if r["split"] == "validation"]
    rules = preferences(items)
    current = active_harness(state)
    if len(feedback) < 2:
        raise ValueError("Record feedback with --use-for-evolution for at least two burst groups.")
    observed = Counter(len({p["sha"] for p in r["group"]["photos"] if p["id"] in r["keep"]})
                       for r in feedback)
    keep_counts = {n for n, count in observed.items() if 1 <= n <= 5 and count >= 2}
    candidates = [
        current | {"burst_keep": n, "burst_rank": rank}
        for n, rank in itertools.product(sorted(keep_counts | {current["burst_keep"]}), sorted(RANKS))
    ]
    feedback_score = metrics(feedback, current, rules)
    improved = []
    for candidate in candidates:
        score = metrics(feedback, candidate, rules)
        if score["edits"] < feedback_score["edits"] and score["unsafe"] <= feedback_score["unsafe"]:
            improved.append({"edits": score["edits"], "unsafe": score["unsafe"], "harness": candidate})
    if not improved:
        print("No repeatable improvement found in burst feedback.")
        return
    if remote:
        best, reason = suggest_burst_skill(model_gateway(), current, improved)
    else:
        best = min(improved, key=lambda item: (item["edits"], item["unsafe"]))["harness"]
        reason = "Reduce edits on opted-in feedback while protecting labeled keepers."
    baseline = metrics(validation, current, rules)
    measured = metrics(validation, best, rules)
    if not qualifies(baseline, measured):
        print(json.dumps({"result": "validation did not qualify", "current": baseline,
                          "candidate": measured, "proposed_harness": best}, indent=2))
        return
    versions = version_store(state)
    identifier = f"v{len(versions['versions'])}"
    versions["versions"][identifier] = {
        "status": "candidate", "parent": versions["active"], "harness": best, "reason": reason,
        "current_metrics": baseline, "candidate_metrics": measured,
    }
    write_json(state / "versions.json", versions)
    print(json.dumps({"candidate": identifier, **versions["versions"][identifier]}, indent=2))
    print(f"Review the changes, then run activate {identifier} --yes to approve.")


def activate(args, state):
    store = version_store(state)
    version = store["versions"].get(args.version)
    if not version or version["status"] != "candidate" or version["parent"] != store["active"]:
        raise ValueError("Choose a pending candidate derived from the active version.")
    items = records(state)
    cases = [r for r in items if r["split"] == "validation"]
    rules = preferences(items)
    baseline = metrics(cases, active_harness(state), rules)
    candidate = metrics(cases, version["harness"], rules)
    if not qualifies(baseline, candidate):
        raise ValueError("Candidate no longer passes the current validation and preferences.")
    version.update(status="approved", current_metrics=baseline, candidate_metrics=candidate)
    store["active"] = args.version
    write_json(state / "versions.json", store)
    print(f"Activated {args.version}.")


def export_plan(state):
    album = manifest(state)
    reviewed = {r["group"]["id"]: r for r in records(state) if r["split"] == "feedback"}
    entries = []
    for group in album["groups"]:
        if item := reviewed.get(group["id"]):
            protected = set(item["keep"] + item["uncertain"])
            root = Path(album["root"])
            for p in group["photos"]:
                file = root / p["path"]
                if p["id"] not in protected:
                    if not file.resolve().is_relative_to(root) or digest(file) != p["sha"]:
                        raise ValueError(f"Photo changed after review: {p['path']}. Rescan first.")
                    entries.append({"path": p["path"], "sha": p["sha"], "group": group["id"]})
    plan = {"root": album["root"], "moves": entries}
    path = state / "cleanup-plan.json"
    write_json(path, plan)
    print(f"{len(entries)} reviewed cleanup candidates: {path}")


def evaluate(state, split):
    items = records(state)
    cases = [r for r in items if r["split"] == split]
    if not cases:
        raise ValueError(f"No {split} annotations.")
    rules = preferences(items)
    print(json.dumps({
        "split": split, "harness": version_store(state)["active"],
        "A_fixed": metrics(cases, BASE, {}),
        "B_preferences": metrics(cases, BASE, rules),
        "C_harness": metrics(cases, active_harness(state), rules),
    }, indent=2))


def main():
    parser = argparse.ArgumentParser(description="Local photo cleanup and harness evolution")
    parser.add_argument("--state", type=Path, default=Path(".album-agent"))
    commands = parser.add_subparsers(required=True, dest="command")
    commands.add_parser("check-model", help="Check model connectivity with a text-only request.")
    scan_cmd = commands.add_parser("scan")
    scan_cmd.add_argument("folder", type=Path)
    scan_cmd.add_argument("--ocr", metavar="TESSERACT")
    commands.add_parser("groups").add_argument("--all", action="store_true")
    show_cmd = commands.add_parser("show")
    show_cmd.add_argument("group")
    show_cmd.add_argument("--blind", action="store_true")
    agent = commands.add_parser("agent", help="Run a tool-using photo review Agent.")
    agent.add_argument("task", nargs="?", default="Find the next photo group worth reviewing.")
    agent.add_argument("--group")
    agent.add_argument("--allow-remote", action="store_true")
    agent.add_argument("--scope", choices=("once", "kind", "global"), default="once")
    agent.add_argument("--rank", choices=sorted(RANKS))
    agent.add_argument("--reason", default="")
    agent.add_argument("--use-for-evolution", action="store_true")
    split = commands.add_parser("split")
    split.add_argument("group")
    split.add_argument("parts", help="Photo numbers separated by commas; separate groups with semicolons.")
    review = commands.add_parser("review")
    review.add_argument("group")
    review.add_argument("--keep")
    review.add_argument("--uncertain")
    review.add_argument("--split", choices=SPLITS, default="feedback")
    review.add_argument("--scope", choices=("once", "kind", "global"), default="once")
    review.add_argument("--rank", choices=sorted(RANKS))
    review.add_argument("--reason", default="")
    review.add_argument("--allow-remote", action="store_true")
    review.add_argument("--use-for-evolution", action="store_true",
                        help="Allow this feedback to inform reusable harness revisions.")
    review.add_argument('--remember-category', help='Remember this explicit content-category decision.')
    review.add_argument('--remember-when', help='Visible conditions defining this category.')
    review.add_argument('--remember-except', help='Exceptions that should remain protected.')
    commands.add_parser("evolve").add_argument("--allow-remote", action="store_true")
    commands.add_parser("export")
    commands.add_parser("evaluate").add_argument("--split", choices=SPLITS[1:], default="test")
    commands.add_parser("versions")
    commands.add_parser('rules', help='Show versioned owner-confirmed semantic preferences.')
    rules_rollback = commands.add_parser('rollback-rules')
    rules_rollback.add_argument('--yes', action='store_true', required=True)
    activation = commands.add_parser("activate")
    activation.add_argument("version")
    activation.add_argument("--yes", action="store_true", required=True)
    rollback = commands.add_parser("rollback")
    rollback.add_argument("--yes", action="store_true", required=True)
    args = parser.parse_args()
    state = args.state.resolve()

    try:
        if args.command == "check-model":
            check_model()
        elif args.command == "scan":
            root = args.folder.resolve(strict=True)
            if not root.is_dir() or root == state or root.is_relative_to(state):
                raise ValueError("Photo folder must be a directory separate from the state directory.")
            bind_state(state, root)
            result = scan(root, state, args.ocr)
            write_json(state / "scan.json", result)
            print(f"{len(result['groups'])} groups, {len(result['skipped'])} warnings in {state / 'scan.json'}.")
        elif args.command == "groups":
            for g in manifest(state)["groups"]:
                if args.all or g["kind"] != "single":
                    print(g["id"], g["kind"], len(g["photos"]), g["photos"][0]["path"])
        elif args.command == "show":
            show(state, find_group(state, args.group), blind=args.blind)
        elif args.command == "agent":
            agent_session(args, state)
        elif args.command == "review":
            record_review(args, state)
        elif args.command == "split":
            split_group(args, state)
        elif args.command == "evolve":
            propose(state, remote=args.allow_remote)
        elif args.command == "versions":
            print(json.dumps(version_store(state), indent=2))
        elif args.command == 'rules':
            print(json.dumps(semantic_preferences.store(state), ensure_ascii=False, indent=2))
        elif args.command == 'rollback-rules':
            print(f'Content preferences rolled back to {semantic_preferences.rollback(state)}.')
        elif args.command == "activate":
            activate(args, state)
        elif args.command == "rollback":
            store = version_store(state)
            parent = store["versions"][store["active"]]["parent"]
            if parent is None:
                raise ValueError("Already on the initial version.")
            store["active"] = parent
            write_json(state / "versions.json", store)
            print(f"Rolled back to {parent}.")
        elif args.command == "evaluate":
            evaluate(state, args.split)
        elif args.command == "export":
            export_plan(state)
    except (OSError, ValueError, EOFError) as error:
        parser.exit(1, f"Error: {error}\n")


if __name__ == "__main__":
    main()

