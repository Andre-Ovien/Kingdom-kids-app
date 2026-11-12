"""Strict bounded-input JSON parsing for signed provider messages."""
import json
import math
from django.views.decorators.debug import sensitive_variables


@sensitive_variables()
def strict_json(raw):
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate JSON key')
            result[key] = value
        return result

    def invalid_constant(_value):
        raise ValueError('Nonfinite JSON number')

    def finite_float(value):
        number = float(value)
        if not math.isfinite(number):
            raise ValueError('Nonfinite JSON number')
        return number

    return json.loads(raw.decode('utf-8'), object_pairs_hook=unique_object,
                      parse_constant=invalid_constant, parse_float=finite_float)
