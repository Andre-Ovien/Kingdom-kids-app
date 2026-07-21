from django.contrib.auth.forms import UserChangeForm, UserCreationForm

from .models import User


class ParentUserCreationForm(UserCreationForm):
    """Admin creation form without Django's default username field."""

    class Meta(UserCreationForm.Meta):
        model = User
        fields = ('email',)


class ParentUserChangeForm(UserChangeForm):
    class Meta(UserChangeForm.Meta):
        model = User
        fields = '__all__'
