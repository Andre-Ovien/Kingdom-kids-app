from django.contrib import admin
from django.contrib.auth.admin import UserAdmin

from .forms import ParentUserChangeForm, ParentUserCreationForm
from .models import (
    EmailVerificationChallenge,
    KidProfile,
    KidProfilePreferences,
    User,
)


@admin.register(User)
class ParentUserAdmin(UserAdmin):
    add_form = ParentUserCreationForm
    form = ParentUserChangeForm
    ordering = ('email',)
    list_display = (
        'email',
        'email_verified_at',
        'is_staff',
        'is_active',
        'date_joined',
    )
    list_filter = ('is_staff', 'is_superuser', 'is_active', 'email_verified_at')
    search_fields = ('email',)

    fieldsets = (
        (None, {'fields': ('email', 'password')}),
        ('Personal info', {'fields': ('first_name', 'last_name')}),
        (
            'Permissions',
            {
                'fields': (
                    'is_active',
                    'is_staff',
                    'is_superuser',
                    'groups',
                    'user_permissions',
                ),
            },
        ),
        (
            'Important dates',
            {'fields': ('email_verified_at', 'last_login', 'date_joined')},
        ),
        (
            'Email verification guard',
            {
                'fields': (
                    'email_verification_failed_attempts',
                    'email_verification_failure_window_started_at',
                    'email_verification_locked_until',
                )
            },
        ),
    )
    add_fieldsets = (
        (
            None,
            {
                'classes': ('wide',),
                'fields': ('email', 'password1', 'password2', 'is_staff', 'is_active'),
            },
        ),
    )


@admin.register(KidProfile)
class KidProfileAdmin(admin.ModelAdmin):
    list_display = ('display_name', 'parent', 'avatar_key', 'created_at')
    list_filter = ('avatar_key',)
    search_fields = ('display_name', 'parent__email')
    list_select_related = ('parent',)
    readonly_fields = ('creation_operation_id', 'created_at', 'updated_at')


@admin.register(KidProfilePreferences)
class KidProfilePreferencesAdmin(admin.ModelAdmin):
    list_display = (
        'profile',
        'story_text_scale',
        'narration_enabled',
        'updated_at',
    )
    list_filter = ('story_text_scale', 'narration_enabled')
    search_fields = ('profile__display_name', 'profile__parent__email')
    list_select_related = ('profile', 'profile__parent')
    readonly_fields = ('updated_at',)


@admin.register(EmailVerificationChallenge)
class EmailVerificationChallengeAdmin(admin.ModelAdmin):
    list_display = (
        'user',
        'created_at',
        'expires_at',
        'attempt_count',
        'consumed_at',
        'invalidated_at',
    )
    list_filter = ('consumed_at', 'invalidated_at')
    search_fields = ('user__email',)
    list_select_related = ('user',)
    readonly_fields = (
        'id',
        'user',
        'code_digest',
        'expires_at',
        'resend_available_at',
        'attempt_count',
        'max_attempts',
        'consumed_at',
        'invalidated_at',
        'created_at',
    )

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False
