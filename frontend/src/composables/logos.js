import { computed } from 'vue'
import { useGlobalConfig } from '@/main'
import { useThemeState } from '@/composables/theme'

export function useLogos() {
  const globalConfig = useGlobalConfig()
  const { theme } = useThemeState()

  const menuLogoPath = computed(() => {
    if (theme.value && theme.value.theme_menu_logo_url) {
      return theme.value.theme_menu_logo_url
    }
    if (globalConfig.MENU_LOGO_PATH) {
      return globalConfig.MENU_LOGO_PATH
    }
    const imgUrl = new URL(
      '@/assets/m-post-office-white.svg',
      import.meta.url
    ).href
    return imgUrl
  })

  const creationFormLogoPath = computed(() => {
    if (theme.value && theme.value.theme_creation_form_logo_url) {
      return theme.value.theme_creation_form_logo_url
    }
    if (globalConfig.CREATION_FORM_LOGO_PATH) {
      return globalConfig.CREATION_FORM_LOGO_PATH
    }
    const imgUrl = new URL(
      '@/assets/m-post-office-blue.svg',
      import.meta.url
    ).href
    return imgUrl
  })

  return {
    menuLogoPath,
    creationFormLogoPath,
  }
}
