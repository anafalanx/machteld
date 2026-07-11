def iban_check(n):
    """Compute the ISO 7064 MOD 97-10 check-digit value for ``n``."""
    return 98 - ((n % 97) * 100 % 97)
