import { PropsWithChildren } from 'react';
import HomeIcon from '@material-ui/icons/Home';
import CreateComponentIcon from '@material-ui/icons/AddCircleOutline';
import TrackChangesIcon from '@material-ui/icons/TrackChanges';
import {
  Sidebar,
  SidebarDivider,
  SidebarGroup,
  SidebarItem,
  SidebarPage,
  SidebarSpace,
} from '@backstage/core-components';
import MenuIcon from '@material-ui/icons/Menu';
import {
  Settings as SidebarSettings,
  UserSettingsSignInAvatar,
} from '@backstage/plugin-user-settings';

export const Root = ({ children }: PropsWithChildren<{}>) => (
  <SidebarPage>
    <Sidebar>
      <SidebarDivider />
      <SidebarGroup label="Menu" icon={<MenuIcon />}>
        <SidebarItem icon={HomeIcon} to="catalog" text="Home" />
        <SidebarItem
          icon={CreateComponentIcon}
          to="create"
          text="Create..."
        />
        <SidebarItem icon={TrackChangesIcon} to="tech-radar" text="Tech Radar" />
        <SidebarDivider />
      </SidebarGroup>
      <SidebarSpace />
      <SidebarDivider />
      <SidebarGroup
        label="Settings"
        icon={<UserSettingsSignInAvatar />}
        to="/settings"
      >
        <SidebarSettings />
      </SidebarGroup>
    </Sidebar>
    {children}
  </SidebarPage>
);
