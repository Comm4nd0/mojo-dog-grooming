from django.contrib import admin

from .models import (
    AppSettings,
    Appointment,
    Breed,
    MedicalNote,
    BookingSeries,
    Client,
    ClientClaimRequest,
    ClosureDay,
    Consent,
    Dog,
    DogPhoto,
    Equipment,
    GroomSession,
    IntakeInvite,
    IntakeSubmission,
    Invoice,
    InvoiceLine,
    OpeningHours,
    PasswordResetRequest,
    PasswordResetToken,
    Payment,
    PhaseTiming,
    ProblemArea,
    TemperamentGrade,
    TodoItem,
    UserProfile,
)


class DogInline(admin.TabularInline):
    model = Dog
    extra = 0
    fields = ['name', 'breed', 'temperament', 'is_active']
    show_change_link = True


class ConsentInline(admin.TabularInline):
    model = Consent
    extra = 0
    # A consent record is evidence of what was agreed on a day. Editing one
    # after the fact would make it worthless, so this is add-and-read only —
    # withdrawing agreement is a new row, which is what the model expects.
    readonly_fields = ['kind', 'agreed', 'signed_name', 'signed_at', 'wording']
    can_delete = False

    def has_add_permission(self, request, obj=None):
        return False


@admin.register(Client)
class ClientAdmin(admin.ModelAdmin):
    list_display = [
        'uid', 'full_name', 'phone', 'email',
        'chatty', 'particular_about_standard', 'leaflet_received', 'user',
    ]
    list_filter = ['chatty', 'particular_about_standard', 'leaflet_received']
    search_fields = ['uid', 'first_name', 'last_name', 'phone', 'email', 'postcode']
    inlines = [DogInline, ConsentInline]


class ProblemAreaInline(admin.TabularInline):
    model = ProblemArea
    extra = 0


@admin.register(Dog)
class DogAdmin(admin.ModelAdmin):
    list_display = [
        'name', 'client', 'breed_label', 'temperament',
        'effective_groom_minutes', 'effective_price',
        'is_ad_hoc', 'is_daycare', 'daycare_days_label', 'is_active',
    ]
    list_filter = ['temperament', 'is_ad_hoc', 'is_daycare', 'is_active', 'breed']
    search_fields = ['name', 'client__first_name', 'client__last_name', 'client__uid', 'client__phone']
    autocomplete_fields = ['client', 'breed']
    inlines = [ProblemAreaInline]


@admin.register(Breed)
class BreedAdmin(admin.ModelAdmin):
    list_display = [
        'name', 'size_band', 'coat_type',
        'avg_groom_minutes', 'avg_price', 'avg_schedule_weeks',
    ]
    list_filter = ['size_band', 'coat_type', 'kennel_club_group', 'activity_level']
    search_fields = ['name']
    list_editable = ['avg_groom_minutes', 'avg_price', 'avg_schedule_weeks']
    fieldsets = [
        ('Groom', {
            'fields': [
                'name', ('size_band', 'coat_type'),
                'avg_groom_minutes', 'avg_price', 'avg_schedule_weeks',
            ],
            'description': (
                'Size band and coat type are the two axes of the price grid in '
                'seed_breeds. Hairless, corded and silky are not on it — those '
                'carry whatever price is set here and nothing is guessed.'
            ),
        }),
        ('The breed', {
            'fields': [
                'kennel_club_group', 'activity_level',
                ('life_span_min_years', 'life_span_max_years'),
                ('height_min_cm', 'height_max_cm'),
                ('weight_min_kg', 'weight_max_kg'),
                'original_purpose', 'typical_temperament',
            ],
        }),
        ('Shape', {
            'fields': ['chest_shape', 'head_type', 'ear_shape', 'tail_shape', 'coat_colours'],
        }),
        ('How it is groomed', {
            'fields': [
                'grooming_technique',
                'groom_style_body', 'groom_style_head', 'groom_style_feet',
                'groom_style_tail', 'groom_style_ears',
            ],
            'description': (
                'These pre-fill a new dog’s grooming preferences in the app. '
                'A starting point per breed, not an override — once a dog has '
                'its own, the dog’s win.'
            ),
        }),
        ('Health', {'fields': ['common_ailments', 'notes']}),
    ]


@admin.register(MedicalNote)
class MedicalNoteAdmin(admin.ModelAdmin):
    """Reference entries. Nothing here is written by the codebase.

    This is veterinary information — see the model. `source` is on the list
    display on purpose: an entry nobody can attribute is one to be wary of.
    """

    list_display = ['title', 'kind', 'source', 'updated_at']
    list_filter = ['kind']
    search_fields = ['title', 'what_it_means', 'grooming_care', 'first_aid']
    filter_horizontal = ['breeds']


@admin.register(Appointment)
class AppointmentAdmin(admin.ModelAdmin):
    list_display = ['dog', 'start_at', 'end_at', 'booking_type', 'status', 'price_quoted']
    list_filter = ['status', 'booking_type']
    search_fields = ['dog__name', 'dog__client__first_name', 'dog__client__last_name']
    autocomplete_fields = ['dog']
    date_hierarchy = 'start_at'


class PhaseTimingInline(admin.TabularInline):
    model = PhaseTiming
    extra = 0


@admin.register(GroomSession)
class GroomSessionAdmin(admin.ModelAdmin):
    list_display = ['dog', 'visit_type', 'started_at', 'total_minutes', 'applied_to_dog_at']
    list_filter = ['visit_type']
    inlines = [PhaseTimingInline]
    autocomplete_fields = ['dog', 'appointment']
    filter_horizontal = ['equipment_used']


class InvoiceLineInline(admin.TabularInline):
    model = InvoiceLine
    extra = 0


class PaymentInline(admin.TabularInline):
    model = Payment
    extra = 0


@admin.register(Invoice)
class InvoiceAdmin(admin.ModelAdmin):
    list_display = ['number', 'client', 'issue_date', 'status', 'total', 'balance']
    list_filter = ['status']
    search_fields = ['number', 'client__first_name', 'client__last_name', 'client__uid']
    inlines = [InvoiceLineInline, PaymentInline]


@admin.register(Equipment)
class EquipmentAdmin(admin.ModelAdmin):
    list_display = ['name', 'uid', 'last_sharpened', 'pat_tested', 'pat_tested_date', 'is_active']
    list_filter = ['pat_tested', 'is_active']
    search_fields = ['name', 'uid']


@admin.register(IntakeSubmission)
class IntakeSubmissionAdmin(admin.ModelAdmin):
    list_display = ['first_name', 'last_name', 'email', 'status', 'created_at', 'created_client']
    list_filter = ['status']
    search_fields = ['first_name', 'last_name', 'email']


@admin.register(ClientClaimRequest)
class ClientClaimRequestAdmin(admin.ModelAdmin):
    list_display = ['user', 'claimed_name', 'claimed_email', 'claimed_postcode', 'matched_client', 'status']
    list_filter = ['status']


@admin.register(PasswordResetToken)
class PasswordResetTokenAdmin(admin.ModelAdmin):
    """Read-only. The token column is deliberately absent — see the note on
    :class:`~api.views.PasswordResetViewSet`; a link that can be read back out
    of a stolen admin session is a link that has been handed over."""

    list_display = ['user', 'created_at', 'expires_at', 'used_at', 'created_by']
    list_filter = ['created_at']
    search_fields = ['user__username', 'user__email']
    readonly_fields = ['user', 'expires_at', 'used_at', 'created_by', 'sent_to', 'created_at']
    exclude = ['token']

    def has_add_permission(self, request):
        return False


@admin.register(PasswordResetRequest)
class PasswordResetRequestAdmin(admin.ModelAdmin):
    list_display = ['identifier', 'user', 'status', 'created_at', 'handled_by', 'handled_at']
    list_filter = ['status']
    search_fields = ['identifier', 'user__username']


@admin.register(TemperamentGrade)
class TemperamentGradeAdmin(admin.ModelAdmin):
    list_display = ['label', 'temperament', 'max_per_day', 'sort_order']
    list_editable = ['max_per_day', 'sort_order']
    # The code is what every dog points at; renaming a grade is editing the
    # label, never repointing the row.
    readonly_fields = ['temperament']


admin.site.register([
    AppSettings,
    BookingSeries,
    ClosureDay,
    DogPhoto,
    IntakeInvite,
    OpeningHours,
    TodoItem,
    UserProfile,
])

admin.site.site_header = 'Mojo and Co'
admin.site.site_title = 'Mojo and Co'
admin.site.index_title = 'Grooming administration'
