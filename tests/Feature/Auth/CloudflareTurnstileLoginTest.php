<?php

use App\Livewire\Settings\Index as SettingsIndex;
use App\Models\InstanceSettings;
use App\Models\Team;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\Client\ConnectionException;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Once;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    config()->set('app.maintenance.store', 'array');
    InstanceSettings::forceCreate(['id' => 0]);
    Once::flush();
});

function enableTurnstile(array $overrides = []): void
{
    instanceSettings()->update([
        'is_cloudflare_turnstile_enabled' => true,
        'cloudflare_turnstile_site_key' => 'site-key',
        'cloudflare_turnstile_secret_key' => 'secret-key',
        ...$overrides,
    ]);
    Once::flush();
}

test('login page renders the turnstile widget only when both keys are configured', function () {
    User::factory()->create();

    $this->get('/login')->assertOk()->assertDontSee('cf-turnstile', false);

    enableTurnstile(['cloudflare_turnstile_secret_key' => null]);
    $this->get('/login')->assertOk()->assertDontSee('challenges.cloudflare.com/turnstile', false);

    enableTurnstile();
    $this->get('/login')
        ->assertOk()
        ->assertSee('challenges.cloudflare.com/turnstile/v0/api.js', false)
        ->assertSee('data-sitekey="site-key"', false);
});

test('login without a turnstile token is rejected when turnstile is enabled', function () {
    Http::preventStrayRequests();
    enableTurnstile();

    $this->post('/login', [
        'email' => 'person@example.com',
        'password' => 'password',
    ])->assertSessionHasErrors('email');

    $this->assertGuest();
});

test('login is rejected when cloudflare reports the token invalid', function () {
    Http::preventStrayRequests();
    Http::fake([
        'https://challenges.cloudflare.com/turnstile/v0/siteverify' => Http::response(['success' => false], 200),
    ]);
    enableTurnstile();
    User::factory()->create(['email' => 'person@example.com']);

    $this->post('/login', [
        'email' => 'person@example.com',
        'password' => 'password',
        'cf-turnstile-response' => 'token',
    ])->assertSessionHasErrors('email');

    $this->assertGuest();
});

test('a verified turnstile token allows the password check to succeed', function () {
    Http::preventStrayRequests();
    Http::fake([
        'https://challenges.cloudflare.com/turnstile/v0/siteverify' => Http::response(['success' => true], 200),
    ]);
    enableTurnstile();
    $user = User::factory()->create(['email' => 'person@example.com']);

    $this->post('/login', [
        'email' => 'person@example.com',
        'password' => 'password',
        'cf-turnstile-response' => 'token',
    ])->assertRedirect();

    $this->assertAuthenticatedAs($user);

    Http::assertSent(function ($request) {
        return $request->url() === 'https://challenges.cloudflare.com/turnstile/v0/siteverify'
            && $request['secret'] === 'secret-key'
            && $request['response'] === 'token';
    });
});

test('a turnstile communication failure is logged and blocks login', function () {
    Http::preventStrayRequests();
    Http::fake(function () {
        throw new ConnectionException('timeout');
    });
    Log::spy();
    enableTurnstile();

    $this->post('/login', [
        'email' => 'person@example.com',
        'password' => 'password',
        'cf-turnstile-response' => 'token',
    ])->assertSessionHasErrors('email');

    Log::shouldHaveReceived('error')->atLeast()->once();
    $this->assertGuest();
});

test('instance settings save the turnstile keys and encrypt the secret', function () {
    $rootTeam = Team::factory()->create(['id' => 0]);
    $user = User::factory()->create();
    $rootTeam->members()->attach($user->id, ['role' => 'owner']);
    $this->actingAs($user);
    session(['currentTeam' => $rootTeam]);

    Livewire::test(SettingsIndex::class)
        ->set('is_cloudflare_turnstile_enabled', true)
        ->set('cloudflare_turnstile_site_key', '  site-key  ')
        ->set('cloudflare_turnstile_secret_key', '  secret-key  ')
        ->call('instantSave');

    $settings = InstanceSettings::findOrFail(0);

    expect($settings->is_cloudflare_turnstile_enabled)->toBeTrue()
        ->and($settings->cloudflare_turnstile_site_key)->toBe('site-key')
        ->and($settings->cloudflare_turnstile_secret_key)->toBe('secret-key')
        ->and($settings->getRawOriginal('cloudflare_turnstile_secret_key'))->not->toBe('secret-key');
});
