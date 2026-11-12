"""Operational checkpoints only; these rows never authorize a payment or grant."""
from django.db import models


class SquareBillingJobState(models.Model):
    environment = models.CharField(max_length=16)
    merchant_sha256 = models.CharField(max_length=64)
    lane = models.CharField(max_length=16)
    cursor = models.CharField(max_length=64, blank=True)
    started_at = models.DateTimeField(null=True, blank=True)
    heartbeat_at = models.DateTimeField(null=True, blank=True)
    finished_at = models.DateTimeField(null=True, blank=True)
    last_completed_at = models.DateTimeField(null=True, blank=True)
    last_finished_outcome = models.CharField(max_length=32, blank=True)
    last_full_scan_at = models.DateTimeField(null=True, blank=True)
    outcome = models.CharField(max_length=32, blank=True)
    counts = models.JSONField(default=dict)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=('environment', 'merchant_sha256', 'lane'), name='square_job_scope_lane'),
            models.CheckConstraint(condition=models.Q(environment__in=('sandbox', 'production')),
                name='square_job_environment'),
            models.CheckConstraint(condition=models.Q(lane__in=('receipts', 'terms', 'renewals')),
                name='square_job_known_lane'),
        ]

