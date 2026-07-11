def semver_cmp(a, apre, b, bpre):
    if a < b:
        return -1
    if a > b:
        return 1

    if apre == bpre:
        return 0
    if apre == 0:
        return 1
    if bpre == 0:
        return -1
    if apre < bpre:
        return -1
    return 1
