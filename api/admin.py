from django.contrib import admin

from .models import (
    AppSettings,
    Appointment,
    Breed,
    BookingSeries,
    Client,
    ClientClaimRequest,
    ClosureDay,
    Dog,
    DogPhoto,
    Equipment,
    GroomSession,
    IntakeInvite,
    IntakeSubmission,
    Invoice,
    InvoiceLine,
    OpeningHours,
    Payment,
    PhaseTiming,
    ProblemArea,
    TemperamentLimit,
    TodoItem,
    UserProfile,
)


class DogInline(admin.TabularInline):
    model = Dog
    extra = 0
    fields = ['name', 'breed', 'temperament', 'is_active']
    show_change_link = True


@admin.register(Client)
class ClientAdmin(admin.ModelAdmin):
    list_display = ['uid', 'full_name', 'phone', 'email', 'chatty', 'leaflet_received', 'user']
    list_filter = ['chatty', 'leaflet_received']
    search_fields = ['uid', 'first_name', 'last_name', 'phone', 'email', 'postcode']
    inlines = [DogInline]


class ProblemAreaInline(admin.TabularInline):
    model = ProblemArea
    extra = 0


@admin.register(Dog)
class DogAdmin(admin.ModelAdmin):
    list_display = ['name', 'client', 'breed_label', 'temperament', 'effective_groom_minutes', 'effective_price', 'is_active']
    list_filter = ['temperament', 'is_active', 'breed']
    search_fields = ['name', 'client__first_name', 'client__last_name', 'client__uid', 'client__phone']
    autocomplete_fields = ['client', 'breed']
    inlines = [ProblemAreaInline]


@admin.register(Breed)
class BreedAdmin(admin.ModelAdmin):
    list_display = ['name', 'coat_type', 'avg_groom_minutes', 'avg_price', 'avg_schedule_weeks']
    search_fields = ['name']
    list_editable = ['avg_groom_minutes', 'avg_price', 'avg_schedule_weeks']


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
    list_display = ['dog', 'started_at', 'total_minutes', 'applied_to_dog_at']
    inlines = [PhaseTimingInline]
    autocomplete_fields = ['dog', 'appointment']


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


@admin.register(TemperamentLimit)
class TemperamentLimitAdmin(admin.ModelAdmin):
    list_display = ['temperament', 'max_per_day']
    list_editable = ['max_per_day']


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
