from django.contrib import admin

from .models import Game, GameAttempt, GameLevel, KidGameProgress


class GameLevelInline(admin.StackedInline):
    model = GameLevel
    extra = 0
    ordering = ('level_number',)


@admin.register(Game)
class GameAdmin(admin.ModelAdmin):
    list_display = (
        'title',
        'game_type',
        'difficulty',
        'is_featured',
        'is_published',
        'sort_order',
        'updated_at',
    )
    list_filter = ('game_type', 'difficulty', 'is_featured', 'is_published')
    list_editable = ('is_featured', 'is_published', 'sort_order')
    search_fields = ('title', 'subtitle', 'description')
    prepopulated_fields = {'slug': ('title',)}
    inlines = (GameLevelInline,)


@admin.register(GameLevel)
class GameLevelAdmin(admin.ModelAdmin):
    list_display = ('game', 'level_number', 'title', 'max_score')
    list_filter = ('game',)
    ordering = ('game__sort_order', 'level_number')
    search_fields = ('game__title', 'title', 'instructions')


@admin.register(KidGameProgress)
class KidGameProgressAdmin(admin.ModelAdmin):
    list_display = (
        'profile',
        'game',
        'highest_completed_level',
        'total_stars',
        'last_played_at',
    )
    list_filter = ('game',)
    search_fields = ('profile__display_name', 'profile__parent__email', 'game__title')
    readonly_fields = ('created_at', 'updated_at')


@admin.register(GameAttempt)
class GameAttemptAdmin(admin.ModelAdmin):
    list_display = (
        'profile',
        'game',
        'level',
        'completed',
        'score',
        'stars',
        'created_at',
    )
    list_filter = ('game', 'completed', 'stars')
    search_fields = (
        'operation_id',
        'profile__display_name',
        'profile__parent__email',
    )
    readonly_fields = (
        'operation_id',
        'profile',
        'game',
        'level',
        'submitted_result',
        'completed',
        'score',
        'stars',
        'feedback',
        'evaluation',
        'created_at',
    )

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False
