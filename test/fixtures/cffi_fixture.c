#include <windows.h>

__declspec(dllimport) int cffi_dependency_value(void);

__declspec(dllexport) int FixtureDependency(void)
{
    return cffi_dependency_value();
}

__declspec(dllexport) const WCHAR *FixtureWideW(const WCHAR *text)
{
    return text;
}

__declspec(dllexport) const WCHAR *FixtureUnpairedW(void)
{
    static const WCHAR text[] = {0xd800, 0};
    return text;
}

__declspec(dllexport) const WCHAR *FixtureMultiW(void)
{
    static const WCHAR text[] = {L'a', 0, 0xdc00, 0, 0};
    return text;
}
