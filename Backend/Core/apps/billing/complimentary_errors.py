"""Static operator diagnostics; never provider/DB/user supplied exception text."""
SAFE_CODES = frozenset({'invalid_owner', 'unresolved_financial_work', 'invalid_expiry',
    'invalid_request', 'invalid_profile', 'grant_conflict', 'grant_not_found', 'internal_error'})


class ComplimentaryRejected(Exception):
    def __init__(self, message, *, code='invalid_request'):
        self.safe_code = code if code in SAFE_CODES else 'internal_error'
        super().__init__(message)
