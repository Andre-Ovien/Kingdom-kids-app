"""The overall learning journey and reward rates shared by every activity."""

# Each entry names exactly one overall XP level. Edit this list to revise ranks.
LEVEL_TITLES = (
    'Little Explorer',
    'Story Scout',
    'Kind Helper',
    'Brave Believer',
    'Faith Adventurer',
    'Hope Bringer',
    'Promise Keeper',
    'Courageous Heart',
    'Wisdom Seeker',
    'Light Bearer',
    'Faithful Guide',
    'Kingdom Builder',
    'Kingdom Guardian',
    'Kingdom Hero',
    'Kingdom Champion',
)
MAX_LEVEL = len(LEVEL_TITLES)
XP_PER_LEVEL = 300
XP_PER_COMPLETED_LEVEL = 50
XP_PER_COMPLETED_STORY = 50
XP_PER_STAR = 20
XP_PER_STREAK_DAY = 20

# Existing progress predates the saved award amount. Preserve that earned XP
# without rewriting historical rows or replay receipts during this rate change.
LEGACY_COMPLETION_XP = 100


def earned_completion_xp(item: dict) -> int:
    """Read a game's saved completion award, preserving unmarked old progress."""

    if item.get('completed') is not True:
        return 0
    amount = item.get('completion_xp')
    return (
        amount
        if type(amount) is int and amount >= 0
        else LEGACY_COMPLETION_XP
    )
