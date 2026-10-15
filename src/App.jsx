// Import component styles so the landing page layout and branding apply.
import "./App.css";

// Import logo assets. Vite will process these imports into bundled URLs at build time.
import codewrkxLogo from "./assets/codewrkx-logo.png";
import awsLogo from "./assets/aws.png";

// Root React component rendered by main.jsx into the #root element.
function App() {
  return (
    // Page shell: centres content vertically and horizontally.
    <div className="app">

      {/* Event / cohort context line shown above the brand cards. */}
      <h3 className="bootcamp-title">
        Codewrkx | Intro to Cloud Engineering (AWS)
      </h3>

      {/* Brand row: Academy and AWS visual identity. */}
      <div className="cards">
        <div className="card">
          <img
            src={codewrkxLogo}
            alt="CodeWrkx"
          />
        </div>

        <div className="card">
          <img
            src={awsLogo}
            alt="GCP"
          />
        </div>
      </div>

      {/* Primary programme banner. */}
      <div className="banner">
        <h1>
          <span>CLAIM </span>
          <span className="gradient">
            COURSE
          </span>
        </h1>
      </div>

      {/* Supporting value statement. */}
      <p className="tagline">
        Self Paced | 2 Hours | Get your certificate at the end 
      </p>

    </div>
  );
}

// Export so main.jsx can mount this component.
export default App;