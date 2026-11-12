from django.contrib import admin

from .models import KidActivityEvent, StreakDailyVisit


@admin.register(KidActivityEvent)
class KidActivityEventAdmin(admin.ModelAdmin):
    """Expose the event ledger for support/debugging without mutation tools."""

    list_display = (
        'id',
        'profile',
        'event_type',
        'story',
        'operation_id',
        'created_at',
    )
    list_filter = ('event_type', 'created_at')
    search_fields = (
        'profile__display_name',
        'profile__parent__email',
        'story__title',
        'operation_id',
    )
    readonly_fields = (
        'id',
        'profile',
        'event_type',
        'story',
        'operation_id',
        'created_at',
    )
    date_hierarchy = 'created_at'

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False


@admin.register(StreakDailyVisit)
class StreakDailyVisitAdmin(admin.ModelAdmin):
    """Expose daily visits for support without mutation tools."""

    list_display = (
        'id',
        'profile',
        'local_date',
        'state',
        'timezone_offset_minutes',
        'created_at',
    )
    list_filter = ('state', 'local_date', 'created_at')
    search_fields = (
        'profile__display_name',
        'profile__parent__email',
    )
    readonly_fields = (
        'id',
        'profile',
        'local_date',
        'state',
        'timezone_offset_minutes',
        'created_at',
    )
    date_hierarchy = 'created_at'

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False
