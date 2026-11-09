# The development signing key

`swinglab-dev.jks` signs every SwingLab APK, whether it is built on a laptop or
by CI. The password is `swinglab-dev`, and it is in `app/build.gradle.kts`.

**Why one fixed key.** Android only installs an update over an existing app when
both are signed with the same key. The only way past a mismatch is to uninstall,
and uninstalling deletes every swing stored on the phone. CI runners make a new
debug key on every run, so without a committed key each download would be a
"different app" and would cost the history to install.

**What committing it gives away.** This repository is public, so anyone can sign
an APK with this key. That matters in exactly one case: if someone got you to
install their APK, Android would accept it as an update to SwingLab and it would
inherit SwingLab's stored data. Install SwingLab only from this repository's CI
artifacts and that case does not arise.

**If that is not good enough** (for example before handing the app to other
people): generate a new key, keep it out of the repository, store it as a GitHub
Actions secret, and decode it in `.github/workflows/android.yml` before the
build. Changing the key once means one uninstall, so export your swings first.
