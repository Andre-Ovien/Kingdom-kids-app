from django.contrib import admin

from .models import NarratorVoice, Story, StoryNarration


class StoryNarrationInline(admin.TabularInline):
    model = StoryNarration
    extra = 0
    autocomplete_fields = ('narrator',)


@admin.register(Story)
class StoryAdmin(admin.ModelAdmin):
    list_display = (
        'title',
        'category',
        'is_published',
        'is_featured',
        'sort_order',
    )
    list_filter = ('is_published', 'is_featured', 'category')
    search_fields = ('title', 'summary', 'body')
    prepopulated_fields = {'slug': ('title',)}
    ordering = ('sort_order', 'title')
    inlines = (StoryNarrationInline,)


@admin.register(NarratorVoice)
class NarratorVoiceAdmin(admin.ModelAdmin):
    list_display = (
        'display_name',
        'avatar_key',
        'voice_key',
        'locale',
        'cached_sample_available',
        'is_active',
    )
    list_filter = ('is_active', 'locale', 'provider')
    search_fields = ('display_name', 'avatar_key', 'voice_key')
    readonly_fields = ('cached_sample_available',)

    @admin.display(boolean=True, description='Cached sample ready')
    def cached_sample_available(self, narrator):
        return narrator.cached_sample_available


@admin.register(StoryNarration)
class StoryNarrationAdmin(admin.ModelAdmin):
    list_display = ('story', 'narrator', 'status', 'audio_available')
    list_filter = ('status', 'narrator')
    search_fields = ('story__title', 'narrator__display_name')
    autocomplete_fields = ('story', 'narrator')
