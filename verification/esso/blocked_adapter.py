#!/usr/bin/env python3
"""Fail closed until a revision-pinned ESSO replay adapter is available."""


def main() -> int:
    print(
        "ESSO lane blocked: no versioned executor adapter currently binds the "
        "Proof Bounty model, Solidity artifact, replay command, and receipt."
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
