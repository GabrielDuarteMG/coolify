<?php

namespace App\Providers;

use App\Actions\Fortify\CreateNewUser;
use App\Actions\Fortify\ResetUserPassword;
use App\Actions\Fortify\UpdateUserPassword;
use App\Models\OauthSetting;
use App\Models\User;
use App\Support\PasskeyRelyingParty;
use App\Support\RootSetupWindow;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\ServiceProvider;
use Illuminate\Validation\ValidationException;
use Laravel\Fortify\Contracts\RegisterResponse;
use Laravel\Fortify\Fortify;

class FortifyServiceProvider extends ServiceProvider
{
    /**
     * Register any application services.
     */
    public function register(): void
    {
        $this->app->instance(RegisterResponse::class, new class implements RegisterResponse
        {
            public function toResponse($request)
            {
                // First user (root) will be redirected to /settings instead of / on registration.
                if ($request->user()->currentTeam()?->id === 0) {
                    return redirect()->route('settings.index');
                }

                return redirect(RouteServiceProvider::HOME);
            }
        });
    }

    /**
     * Bootstrap any application services.
     */
    public function boot(): void
    {
        Fortify::createUsersUsing(CreateNewUser::class);
        Fortify::registerView(function () {
            $isFirstUser = User::count() === 0;

            $settings = instanceSettings();
            if (! $settings->isPasswordRegistrationAllowed()) {
                return redirect()->route('login');
            }

            return view('auth.register', [
                'isFirstUser' => $isFirstUser,
                'isRootSetupWindowClosed' => $isFirstUser && ! RootSetupWindow::isOpen(),
            ]);
        });

        Fortify::loginView(function () {
            $settings = instanceSettings();
            $enabled_oauth_providers = OauthSetting::where('enabled', true)->get();
            $users = User::count();
            if ($users == 0 && $settings->isPasswordRegistrationAllowed()) {
                // If there are no users and password registration is allowed, redirect to registration.
                return redirect()->route('register');
            }

            return view('auth.login', [
                'is_registration_enabled' => $settings->isPasswordRegistrationAllowed(),
                'can_register_with_oauth' => $enabled_oauth_providers->contains(
                    fn (OauthSetting $oauthSetting) => $oauthSetting->couldBeEnabled() && $oauthSetting->allowsUserCreation()
                ),
                'enabled_oauth_providers' => $enabled_oauth_providers,
                'passkeys_available' => PasskeyRelyingParty::isAvailable(),
                'is_cloudflare_turnstile_enabled' => (bool) ($settings->is_cloudflare_turnstile_enabled && filled($settings->cloudflare_turnstile_site_key) && filled($settings->cloudflare_turnstile_secret_key)),
                'cloudflare_turnstile_site_key' => $settings->cloudflare_turnstile_site_key,
            ]);
        });

        Fortify::authenticateUsing(function (Request $request) {
            $this->assertCloudflareTurnstile($request);

            $email = strtolower($request->email);
            $user = User::where('email', $email)->with('teams')->first();
            if (
                $user &&
                Hash::check($request->password, $user->password)
            ) {
                $user->updated_at = now();
                $user->save();

                // Pending team invitations are not accepted here; the user accepts
                // them explicitly on the invitation page (team.invitation.show).
                // Restore the last active team; only fall back when unambiguous.
                $team = $user->resolveStoredTeam();
                if (! $team && $user->teams->isEmpty()) {
                    $team = $user->recreate_personal_team();
                }
                if ($team) {
                    session(['currentTeam' => $team]);
                }
                // Otherwise (multiple teams, no stored choice) leave the session
                // team unset so the user is sent to the team-selection screen.

                return $user;
            }
        });
        Fortify::requestPasswordResetLinkView(function () {
            return view('auth.forgot-password');
        });
        Fortify::resetPasswordView(function ($request) {
            return view('auth.reset-password', ['request' => $request]);
        });
        Fortify::resetUserPasswordsUsing(ResetUserPassword::class);

        Fortify::updateUserPasswordsUsing(UpdateUserPassword::class);

        Fortify::confirmPasswordView(function () {
            return view('auth.confirm-password', [
                'can_confirm_with_passkey' => PasskeyRelyingParty::isAvailable()
                    && auth()->user()->hasPasskeysEnabled(),
            ]);
        });

        Fortify::twoFactorChallengeView(function () {
            return view('auth.two-factor-challenge');
        });
    }

    /**
     * Reject the login when Cloudflare Turnstile is configured and the token does not verify.
     */
    private function assertCloudflareTurnstile(Request $request): void
    {
        $settings = instanceSettings();
        if (! $settings->is_cloudflare_turnstile_enabled || blank($settings->cloudflare_turnstile_site_key) || blank($settings->cloudflare_turnstile_secret_key)) {
            return;
        }

        $token = $request->input('cf-turnstile-response');
        if (! is_string($token) || $token === '') {
            throw ValidationException::withMessages([
                'email' => 'Please complete the Cloudflare Turnstile challenge.',
            ]);
        }

        try {
            $response = Http::asForm()->timeout(10)->post('https://challenges.cloudflare.com/turnstile/v0/siteverify', [
                'secret' => $settings->cloudflare_turnstile_secret_key,
                'response' => $token,
                'remoteip' => $request->ip(),
            ]);
        } catch (\Throwable $exception) {
            Log::error('Cloudflare Turnstile siteverify request failed.', [
                'exception' => $exception::class,
                'message' => $exception->getMessage(),
            ]);

            throw ValidationException::withMessages([
                'email' => 'Cloudflare Turnstile could not be verified. Please try again.',
            ]);
        }

        if (! $response->successful()) {
            Log::error('Cloudflare Turnstile siteverify returned an unexpected response.', [
                'status' => $response->status(),
            ]);

            throw ValidationException::withMessages([
                'email' => 'Cloudflare Turnstile could not be verified. Please try again.',
            ]);
        }

        if ($response->json('success') !== true) {
            throw ValidationException::withMessages([
                'email' => 'Cloudflare Turnstile verification failed. Please try again.',
            ]);
        }
    }
}
