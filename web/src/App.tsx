import { Navigate, Route, Routes } from 'react-router-dom';
import { Layout } from './components/Layout';
import { Spinner } from './components/ui';
import { useAuth } from './lib/auth';
import { ProjectProvider } from './lib/project';
import { Access } from './pages/Access';
import { Alerts } from './pages/Alerts';
import { Audit } from './pages/Audit';
import { Billing } from './pages/Billing';
import { Dashboard } from './pages/Dashboard';
import { DbLab } from './pages/DbLab';
import { Launch } from './pages/Launch';
import { Login } from './pages/Login';
import { Logs } from './pages/Logs';
import { Monitoring } from './pages/Monitoring';
import { ResourceDetail } from './pages/ResourceDetail';
import { Resources } from './pages/Resources';

export default function App() {
  const { user, loading } = useAuth();
  if (loading) return <Spinner label="Restoring session" />;
  if (!user) return <Login />;
  return (
    <ProjectProvider>
      <Routes>
        <Route element={<Layout />}>
          <Route index element={<Dashboard />} />
          <Route path="resources" element={<Resources />} />
          <Route path="resources/:id" element={<ResourceDetail />} />
          <Route path="launch" element={<Launch />} />
          <Route path="monitoring" element={<Monitoring />} />
          <Route path="logs" element={<Logs />} />
          <Route path="alerts" element={<Alerts />} />
          <Route path="billing" element={<Billing />} />
          <Route path="access" element={<Access />} />
          <Route path="audit" element={<Audit />} />
          <Route path="lab" element={<DbLab />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Route>
      </Routes>
    </ProjectProvider>
  );
}
