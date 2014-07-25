Name:           kurado_agent
Version:        20140725
Release:        838
Summary:        Daemon for Kurado Server Performance Metrics

Group:          Application/Deamon
License:        Artistic
URL:            https://github.com/kazeburo/Kurado
Source0:        https://raw.githubusercontent.com/kazeburo/Kurado/master/agent_fatpack/kurado_agent
Source1:        kurado_agent.initd
Source2:        kurado_agent.logrotate
Source3:        kurado_agent.sysconf
BuildArch:      noarch
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-%(%{__id_u} -n)
Requires:       perl

%description
Daemon for Kurado Server Performance Metrics

%install
rm -rf $RPM_BUILD_ROOT

mkdir -p $RPM_BUILD_ROOT%{_sysconfdir}/kurado_agent
mkdir -p $RPM_BUILD_ROOT%{_sysconfdir}/init.d
install -m 755 %{SOURCE1} $RPM_BUILD_ROOT%{_sysconfdir}/init.d/kurado_agent
mkdir -p $RPM_BUILD_ROOT%{_sysconfdir}/sysconfig
install -m 755 %{SOURCE2} $RPM_BUILD_ROOT%{_sysconfdir}/sysconfig/kurado_agent
mkdir -p $RPM_BUILD_ROOT%{_sysconfdir}/logrotate.d
install -m 755 %{SOURCE3} $RPM_BUILD_ROOT%{_sysconfdir}/logrotate.d/kurado_agent

%post
/sbin/chkconfig --add httpd_proxy

%files
%defattr(-,root,root,-)
%dir %{_sysconfdir}/kurado_agent
%config %{_sysconfdir}/init.d/kurado_agent
%config(noreplace) %{_sysconfdir}/sysconfig/kurado_agent
%config(noreplace) %{_sysconfdir}/logrotate.d/kurado_agent

%changelog

