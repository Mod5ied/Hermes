package speech

import "strings"

func whisperLanguage(locale string) string {
	locale = strings.TrimSpace(strings.ToLower(locale))
	if locale == "" {
		return "en"
	}
	if index := strings.IndexAny(locale, "-_"); index >= 0 {
		locale = locale[:index]
	}
	if len(locale) < 2 || len(locale) > 3 {
		return "en"
	}
	return locale
}
