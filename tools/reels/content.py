"""100 product-focused MirrorUE memes (benefits, not internals)."""

from __future__ import annotations

BRAND = {
    "name": "MirrorUE",
    "url": "kamilbourouiba.github.io/MirrorUE",
    "download": "https://github.com/KamilBourouiba/MirrorUE/releases/latest",
    "cta_short": "MirrorUE · Free on Mac",
    "cta_url": "mirrorue.dev",
}

PERSONAS = {
    "lucas": {"name": "Lucas", "role": "Indie iOS developer"},
    "sarah": {"name": "Sarah", "role": "Mobile QA engineer"},
    "thomas": {"name": "Thomas", "role": "Creator and iOS trainer"},
    "nadia": {"name": "Nadia", "role": "QA lead, mobile startup"},
}

HASHTAG_SETS = {
    "lucas": ["#iOSDev", "#IndieDev", "#AppDemo", "#macOS", "#MirrorUE"],
    "sarah": ["#MobileQA", "#QAEngineer", "#TestAutomation", "#MirrorUE"],
    "thomas": ["#ContentCreator", "#iOSTutorial", "#TechTok", "#MirrorUE"],
    "nadia": ["#QALead", "#StartupLife", "#MobileTesting", "#MirrorUE"],
    "default": ["#MirrorUE", "#iPhone", "#macOS", "#FreeDownload"],
}

CTAS = [
    "MirrorUE · Free on Mac · link in bio",
    "Download free · mirrorue.dev",
    "Try MirrorUE — free and open source",
    "Mirror your iPhone · free download",
]

# (template, text lines, caption) — product benefits only, plain English
LUCAS: list[tuple[str, list[str], str]] = [
    ("morpheus", ["Simulator for the client demo", "Their real iPhone on your Mac"], "Show clients the app on hardware they actually hold."),
    ("mordor", ["One does not simply demo keyboard feel in Simulator", "Mirror the real iPhone instead"], "Real layout, real keyboard, real surprises caught early."),
    ("morpheus", ["What if you could click the app with a mouse", "While the client watches on your Mac"], "Live demos without thumb gymnastics."),
    ("success", ["Plugged in my iPhone", "Nailed the client walkthrough"], "Smooth mirror up to 120 fps for presentations."),
    ("wonka", ["So Simulator was enough for the demo", "Tell me more"], "When the client asks about device-only bugs."),
    ("rollsafe", ["Typing on the tiny phone screen", "Mac keyboard on the mirrored app"], "AZERTY and QWERTY just work."),
    ("fine", ["Simulator mismatch is fine", "The client found a keyboard bug"], "Demo on real hardware before the meeting."),
    ("both", ["Simulator for quick checks", "Real iPhone on Mac for demos", "Why not both"], "Use the right tool for each moment."),
    ("interesting", ["I don't always demo to clients", "But when I do it's on a real iPhone"], "Confidence beats guesswork."),
    ("buzz", ["Surprise bugs everywhere", "When the demo never left Simulator"], "Your portfolio deserves a real device pass."),
    ("pigeon", ["iOS developer", "Live app on Mac screen", "Is this the client demo"], "MirrorUE turns your phone into a Mac window."),
    ("rollsafe", ["Can't freeze during the live demo", "If the real app is on your desktop"], "Mouse control keeps you calm on stage."),
    ("woman-cat", ["Just use slides for the demo", "Show the live app on a mirrored iPhone"], "Clients remember product, not bullet points."),
    ("officespace", ["If you could demo on real hardware", "That'd be great"], "Free mirror for phones you own and trust."),
    ("patrick", ["Let's hide behind Simulator", "How about the actual device on screen"], "Ship demos that match what users touch."),
    ("spongebob", ["sImUlAtOr Is EnOuGh", "Real iPhone mirror on Mac"], "Indie devs still need real-device truth."),
    ("leo", ["Walk into the client call", "With a buttery 120 fps device demo"], "Look pro without a pro budget."),
    ("fry", ["Not sure if it's an app bug", "Or Simulator lying again"], "Stop debating — mirror the phone."),
    ("doge", ["Much demo", "Very real device", "Such mirror"], "MirrorUE — free for your dev iPhone."),
    ("bihw", ["Demoing on a physical iPhone", "But it's honest work"], "The work that wins client trust."),
    ("db", ["Simulator only", "Real iPhone on Mac", "Client sees the truth"], "Pick the screen that matches reality."),
    ("patrick", ["Another mirror subscription", "Free MirrorUE on your Mac"], "No account. No cloud. Your device."),
    ("mordor", ["One does not simply trust rotation in Simulator", "Let the mirror follow the phone"], "Portrait and landscape stay in sync."),
    ("success", ["Screenshot the bug in one click", "Sent it before the call ended"], "Capture while you control from Mac."),
    ("handshake", ["You bring the app", "MirrorUE brings the live window", "Client brings the trust"], "Simple setup. Serious demos."),
]

SARAH: list[tuple[str, list[str], str]] = [
    ("mordor", ["Tap login fifty times by hand", "Watch and control it on your Mac"], "See every step on a big screen."),
    ("fine", ["Manual regression is fine", "Running checkout again until Friday"], "Your thumb deserves a break."),
    ("gb", ["Same taps every sprint", "Spreadsheet of test steps", "Mirror the real device on Mac", "Save paths and replay with Pro"], "Less repetition. More coverage."),
    ("officespace", ["If you could run login one more time", "That'd be great"], "Every QA team knows this voice."),
    ("panik-kalm-panik", ["Release week manual testing", "Everyone sees the flow on Mac", "Ship with confidence"], "Visual control before automation sprawl."),
    ("interesting", ["Bug only shows on real device", "Mirror that iPhone instantly"], "Repro what Simulator misses."),
    ("woman-cat", ["Stop guessing in Simulator", "Test on a mirrored iPhone"], "Real hardware, real results."),
    ("spiderman", ["Tester A's steps", "Tester B's different steps"], "Same mirror, same visibility."),
    ("same", ["Hours in Simulator", "Same bugs in production", "They're the same gap"], "Close it with device testing on Mac."),
    ("handshake", ["QA sees the screen", "Dev sees the same mirror", "Bugs caught faster"], "One view of the truth."),
    ("mordor", ["One does not simply skip device QA", "Mirror the phone on your desk"], "Real devices you already own."),
    ("success", ["Reproduced on hardware", "Logged it before standup"], "Fast eyes on real flows."),
    ("rollsafe", ["Can't miss the repro steps", "If QA watches live on Mac"], "Big screen beats squinting at a phone."),
    ("fry", ["Not sure if the test is flaky", "Or Simulator is the flake"], "Settle it on a mirrored device."),
    ("buzz", ["Edge cases everywhere", "When testing never left Simulator"], "Production is not a simulator."),
    ("pigeon", ["QA engineer", "Real device on Mac", "Is this the repro"], "Finally see what the tester sees."),
    ("interesting", ["I don't always test manually", "But when I do it's on hardware"], "Manual where it matters."),
    ("wonka", ["So you love running checkout forty times", "Tell me more"], "There is a better way coming in Pro."),
    ("bihw", ["Testing purchase on a real iPhone", "But it's honest work"], "Honest work your users depend on."),
    ("spongebob", ["Weeks setting up heavy automation", "Start by mirroring and controlling visually"], "Meet the team where they are."),
    ("officespace", ["If you could see the test live on Mac", "That'd be great"], "Free tier today. Paths in Pro."),
    ("astronaut", ["Wait it's all manual taps", "Always has been", "Unless you save test paths", "MirrorUE Pro"], "Evolve when repetition hurts."),
    ("spongebob", ["mAnUaL rEgReSsIoN", "Mirror and control from Mac"], "Make manual testing less painful."),
    ("both", ["Simulator only", "Real iPhone mirror", "Why not both on one Mac"], "Cover more ground without more tools."),
    ("fine", ["Flaky tests are fine", "I'll tap through checkout again"], "Your weekend called. It wants a life."),
]

THOMAS: list[tuple[str, list[str], str]] = [
    ("mordor", ["Film the phone with another phone", "Record clean from your Mac"], "One window for control and capture."),
    ("db", ["QuickTime plus phone stand chaos", "MirrorUE screen record", "Tutorial ready"], "Stop the three-app shuffle."),
    ("bihw", ["Recording real iOS tutorials", "But it's honest work"], "Honest footage beats shaky B-roll."),
    ("rollsafe", ["Can't ruin the take", "If you replay the same demo path"], "Pro paths for identical tutorials."),
    ("woman-cat", ["Buy another capture app", "Mirror and record in one place"], "Creators need fewer tabs open."),
    ("success", ["Hit record on Mac", "Uploaded the Reel same day"], "HEVC recording with touch dots shown."),
    ("leo", ["Shaky desk footage", "Smooth 120 fps screen capture"], "Viewers notice lag before you do."),
    ("interesting", ["I don't always reshoot tutorials", "But when I do I mirror first"], "Get the take right faster."),
    ("mordor", ["One does not simply film a phone screen", "Record from the Mac mirror"], "Clean frames. No camera glare."),
    ("buzz", ["Soft glitchy clips everywhere", "When you filmed the display"], "Your tutorial deserves sharp UI."),
    ("leo", ["Tutorial upload day", "Crisp iPhone demo footage"], "Look polished on a free tool."),
    ("fry", ["Not sure if bad take", "Or bad camera angle"], "Eliminate the camera variable."),
    ("pigeon", ["Tutorial creator", "iPhone on Mac", "Is this the B-roll"], "Yes. Yes it is."),
    ("both", ["Phone on a stand", "Mac screen recording", "Why not both in one app"], "MirrorUE combines the workflow."),
    ("wonka", ["So you sync four apps per video", "Tell me more"], "Creators should create, not wrangle tools."),
    ("fine", ["Soft footage is fine", "Three hours color grading later"], "Start with a clean source capture."),
    ("patrick", ["Add another capture subscription", "How about free mirror and record"], "Start free. Upgrade for replay paths."),
    ("spongebob", ["qUiCkTiMe aNd A pHoNe StAnD", "One mirror on Mac"], "Simplify the stack."),
    ("success", ["Fullscreen demo mode", "Subscribers see every button"], "Native fullscreen when you need impact."),
    ("rollsafe", ["Won't lose the pointer", "If you control from Mac"], "Mouse beats finger covers on screen."),
    ("both", ["Re-shoot the whole lesson", "Replay the exact same demo"], "Pro paths for series creators."),
    ("officespace", ["If you could show touches on screen", "That'd be great"], "Show-touches is built in."),
    ("handshake", ["Clean video", "Fast workflow", "More uploads per week"], "Volume comes from less friction."),
    ("woman-cat", ["Ring light plus three apps", "MirrorUE is free on Mac"], "Spend budget on content, not capture tax."),
    ("doge", ["Much smooth", "Very 120fps", "Such tutorial"], "Free download — link in bio."),
]

NADIA: list[tuple[str, list[str], str]] = [
    ("woman-cat", ["Six-month cloud phone farm", "Use the iPhones on your desks"], "Start local before you scale cloud."),
    ("same", ["Expensive device lab quote", "Five iPhones and Mac mirrors", "Same QA coverage"], "Fleet for when the team grows."),
    ("handshake", ["Shared test paths", "Volume seats for the team", "Less manual busywork"], "MirrorUE Fleet — waitlist open."),
    ("astronaut", ["Wait it's all manual regression", "Always has been", "Unless paths are shared", "MirrorUE Fleet"], "Standardize before you drown."),
    ("spiderman", ["Everyone tests differently", "Same saved paths for all"], "Stop reinventing every release."),
    ("panik-kalm-panik", ["Hire three more manual testers", "Give everyone the same mirror tool"], "Multiply eyes, not headcount."),
    ("fine", ["Pre-release panic is fine", "We'll run everything by hand again"], "There is a smarter middle ground."),
    ("panik-kalm-panik", ["Release week chaos", "Team runs shared workflows", "Ship calm"], "Reproducible beats heroic."),
    ("officespace", ["If the whole team ran the same test", "That'd be great"], "Shared library coming with Fleet."),
    ("wonka", ["So manual regression scales forever", "Tell me more"], "Your team deserves leverage."),
    ("mordor", ["One does not simply ship without device QA", "Mirror every test phone"], "Real devices. Real sign-off."),
    ("success", ["Team aligned on test paths", "Released on time"], "Process without a phone farm bill."),
    ("gb", ["Email chains of steps", "Everyone tests differently", "Shared paths on Mac", "MirrorUE Fleet"], "Galaxy brain for QA leads."),
    ("handshake", ["QA lead", "Engineers", "One workflow library"], "Onboarding support included in Fleet."),
    ("woman-cat", ["Buy cloud devices now", "We already own the phones"], "Use the hardware on the table."),
    ("interesting", ["I don't always buy new infrastructure", "But when I do we start local"], "Prove ROI before big spend."),
    ("buzz", ["Manual test debt everywhere", "Before every production push"], "Pay it down with shared paths."),
    ("pigeon", ["Startup QA lead", "Row of iPhones", "Is this our phone lab"], "It can be — on Mac, today."),
    ("both", ["Cloud device farm", "Desks full of iPhones", "Why not start local"], "Fleet when you outgrow free."),
    ("rollsafe", ["Can't slip the release date", "If paths are saved and replayed"], "Pro today. Fleet for the team."),
    ("fry", ["Not sure if process is broken", "Or we lack shared tests"], "Fix visibility first with mirrors."),
    ("bihw", ["Coordinating manual QA across five people", "But it's honest work"], "Make honest work repeatable."),
    ("officespace", ["Vendor rollout all year", "MirrorUE Fleet this quarter"], "Move faster with what you have."),
    ("spiderman", ["Custom script per tester", "Same path everyone runs"], "Stop snowflake test setups."),
    ("success", ["Onboarded QA in one afternoon", "Everyone mirroring from Mac"], "Low friction wins startups."),
]


def _slug(persona: str, index: int) -> str:
    return f"{persona}-{index:02d}"


def build_memes() -> list[dict]:
    out: list[dict] = []
    banks = [
        ("lucas", LUCAS),
        ("sarah", SARAH),
        ("thomas", THOMAS),
        ("nadia", NADIA),
    ]
    for persona, specs in banks:
        for i, (template, text, caption) in enumerate(specs, start=1):
            out.append({
                "id": _slug(persona, i),
                "persona": persona,
                "provider": "memegen",
                "template": template,
                "text": text,
                "caption": caption,
                "hashtags": persona,
                "cta_index": len(out) % len(CTAS),
            })
    return out


def build_catalog() -> dict:
    return {
        "brand": BRAND,
        "personas": PERSONAS,
        "hashtag_sets": HASHTAG_SETS,
        "ctas": CTAS,
        "memes": build_memes(),
    }
